import Foundation

/// Pure planning for a port-forward tunnel: the `ssh -N` arguments, how to
/// tell it is up from ssh's output, and what to tell the user. No I/O —
/// `PortForwardManager` runs it.
enum PortForwardPlan {
    /// Printed by ssh at `LogLevel=VERBOSE` once login succeeded; forwards are
    /// set up right after (and a busy port then exits, `ExitOnForwardFailure`).
    static let authenticatedPrefix = "Authenticated to "

    /// How long the tunnel must stay alive after login to count as up: long
    /// enough for a busy local port to make ssh exit first.
    static let settleDelay: TimeInterval = 0.6

    /// Built from the host's connection fields (not `host.sshCommand`) so the
    /// host's own forwards / startup command don't leak into the tunnel.
    static func arguments(for forward: PortForward, host: SavedHost) -> [String] {
        var args = [
            "-N",                                   // no remote command — tunnel only
            "-o", "ExitOnForwardFailure=yes",       // fail fast if the port is busy
            "-o", "LogLevel=VERBOSE",               // "Authenticated to …" marks login
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]
        args += SSHBackgroundArgs.connection(for: host) + SSHBackgroundArgs.identity(for: host)
        if host.forwardAgent { args.append("-A") }
        args += forwardArgs(forward)
        return args + [host.sshTarget]
    }

    static func forwardArgs(_ forward: PortForward) -> [String] {
        let destination = "\(forward.destinationHost):\(forward.destinationPort)"
        switch forward.kind {
        case .local:   return ["-L", "\(forward.bindAddress):\(forward.listenPort):\(destination)"]
        case .remote:  return ["-R", "\(forward.bindAddress):\(forward.listenPort):\(destination)"]
        case .dynamic: return ["-D", "\(forward.bindAddress):\(forward.listenPort)"]
        }
    }

    static func hasAuthenticated(_ stderr: String) -> Bool {
        stderr.split(whereSeparator: \.isNewline).contains { $0.hasPrefix(authenticatedPrefix) }
    }

    static func failureReason(stderr: String, status: Int32, forward: PortForward) -> String {
        if stderr.contains("Address already in use") {
            return forward.kind == .remote
                ? "Port \(forward.listenPort) is already in use on the server."
                : "Port \(forward.listenPort) is already in use on this Mac. Stop whatever uses it, or pick another port."
        }
        return SSHBackgroundArgs.failureReason(stderr: stderr, status: status)
    }

    /// What to connect to on this Mac: the local end of a -L or -D tunnel.
    static func localAddress(for forward: PortForward) -> String? {
        forward.kind == .remote ? nil : "\(forward.bindAddress):\(forward.listenPort)"
    }

    static func successMessage(for forward: PortForward, host: SavedHost) -> String {
        let via = host.proxyJump.isEmpty ? "" : " via \(host.proxyJump)"
        let route = "\(forward.route)\nthrough \(host.sshTarget)\(via)"
        switch forward.kind {
        case .local:   return "\(route)\n\nConnect to it on this Mac at:"
        case .dynamic: return "\(route)\n\nSet this as the SOCKS proxy:"
        case .remote:  return "\(route)\n\nThe server now forwards port \(forward.listenPort) to this Mac."
        }
    }
}
