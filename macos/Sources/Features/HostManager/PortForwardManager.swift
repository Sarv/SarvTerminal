import Foundation
import Combine

/// Launches and tracks long-lived `ssh -N` tunnel processes for the saved
/// `PortForward` rules. `@MainActor` so it can publish running state to SwiftUI;
/// each tunnel is a detached `ssh` process whose exit is reported back on the
/// main actor.
@MainActor
final class PortForwardManager: ObservableObject {
    static let shared = PortForwardManager()

    /// IDs of rules whose tunnel is currently up.
    @Published private(set) var running: Set<UUID> = []
    /// Last error per rule (cleared when it starts cleanly).
    @Published private(set) var errors: [UUID: String] = [:]

    /// A live tunnel: the ssh process + the askpass temp file to clean up, and
    /// whether the user asked it to stop (so we don't flag a manual stop as an error).
    private final class Tunnel {
        let process: Process
        let askpassFile: String?
        var manualStop = false
        init(process: Process, askpassFile: String?) {
            self.process = process
            self.askpassFile = askpassFile
        }
    }

    private var tunnels: [UUID: Tunnel] = [:]

    private init() {}

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    /// Start the tunnel if stopped, stop it if running.
    func toggle(_ forward: PortForward) {
        if running.contains(forward.id) { stop(forward.id) } else { start(forward) }
    }

    // MARK: - Start

    func start(_ forward: PortForward) {
        guard tunnels[forward.id] == nil else { return }
        errors[forward.id] = nil
        guard let host = SavedHostsStore.shared.host(withID: forward.hostID) else {
            errors[forward.id] = "The host for this tunnel no longer exists."
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = sshArguments(for: forward, host: host)
        // No controlling TTY → ssh uses SSH_ASKPASS for the password (if any).
        proc.standardInput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice

        var askpassFile: String?
        if host.authMethod == .password || host.authMethod == .ask, !host.password.isEmpty {
            let env = SSHAskpass.env(forPassword: host.password)
            askpassFile = env["SARV_ASKPASS_FILE"]
            proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        }

        let tunnel = Tunnel(process: proc, askpassFile: askpassFile)
        proc.terminationHandler = { [weak self] p in
            let errText = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { $0.flatMap { String(data: $0, encoding: .utf8) } } ?? ""
            Task { @MainActor in self?.tunnelDidExit(forward.id, status: p.terminationStatus, stderr: errText) }
        }

        do {
            try proc.run()
        } catch {
            errors[forward.id] = "Couldn't launch ssh: \(error.localizedDescription)"
            cleanup(askpassFile)
            return
        }
        tunnels[forward.id] = tunnel
        running.insert(forward.id)
    }

    // MARK: - Stop

    func stop(_ id: UUID) {
        guard let tunnel = tunnels[id] else { return }
        tunnel.manualStop = true
        if tunnel.process.isRunning { tunnel.process.terminate() }
        // terminationHandler does the bookkeeping + cleanup.
    }

    func stopAll() {
        for id in Array(tunnels.keys) { stop(id) }
    }

    // MARK: - Exit handling

    private func tunnelDidExit(_ id: UUID, status: Int32, stderr: String) {
        let tunnel = tunnels[id]
        running.remove(id)
        tunnels[id] = nil
        cleanup(tunnel?.askpassFile)
        // A clean manual stop (or status 0) isn't an error; a non-zero exit while
        // we expected it up means the tunnel dropped or failed to bind.
        if tunnel?.manualStop != true, status != 0 {
            let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            errors[id] = msg.isEmpty ? "Tunnel exited unexpectedly (code \(status))." : msg
        }
    }

    private func cleanup(_ askpassFile: String?) {
        guard let askpassFile else { return }
        try? FileManager.default.removeItem(atPath: askpassFile)
    }

    // MARK: - Command construction

    /// Build the `ssh` argument vector for a tunnel. We assemble it from the
    /// host's connection fields directly (rather than `host.sshCommand`) so the
    /// host's OWN forwards / initial command don't leak into the tunnel.
    private func sshArguments(for forward: PortForward, host: SavedHost) -> [String] {
        var args = [
            "-N",                                       // no remote command — tunnel only
            "-o", "ExitOnForwardFailure=yes",           // fail fast if the port is busy
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
        ]
        if host.port != 22 { args += ["-p", "\(host.port)"] }
        if !host.identityFile.isEmpty {
            args += ["-i", expandTilde(host.identityFile), "-o", "IdentitiesOnly=yes"]
        }
        if host.forwardAgent { args.append("-A") }

        switch forward.kind {
        case .local:
            args += ["-L", "\(forward.bindAddress):\(forward.listenPort):\(forward.destinationHost):\(forward.destinationPort)"]
        case .remote:
            args += ["-R", "\(forward.bindAddress):\(forward.listenPort):\(forward.destinationHost):\(forward.destinationPort)"]
        case .dynamic:
            args += ["-D", "\(forward.bindAddress):\(forward.listenPort)"]
        }

        let target = host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)"
        args.append(target)
        return args
    }

    private func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSHomeDirectory() + path.dropFirst()
    }
}
