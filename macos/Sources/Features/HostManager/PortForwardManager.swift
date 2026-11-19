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

    /// A live tunnel: the ssh process, the broker answering its prompts, what
    /// it printed so far, and whether the user asked it to stop (a manual stop
    /// isn't an error) or it was already reported as up.
    private final class Tunnel {
        let process: Process
        let forward: PortForward
        let host: SavedHost
        let broker: SSHPromptBroker?
        /// Human-readable label for notifications (rule name + host).
        let label: String
        var stderr = ""
        var manualStop = false
        /// ssh printed "Authenticated to …" (forwards are being set up).
        var loggedIn = false
        /// Stayed up past the settle delay and the user was told.
        var announced = false
        init(process: Process, forward: PortForward, host: SavedHost, broker: SSHPromptBroker?, label: String) {
            self.process = process
            self.forward = forward
            self.host = host
            self.broker = broker
            self.label = label
        }
    }

    /// stderr kept per tunnel: enough for the failure line, bounded for a
    /// tunnel that runs for days.
    private static let stderrLimit = 16_384

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
        proc.arguments = PortForwardPlan.arguments(for: forward, host: host)
        // No controlling TTY: every prompt (host keys, passwords, for the
        // target and each jump host) goes to the broker via SSH_ASKPASS.
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        let broker = SSHPromptBroker(
            credentials: SSHJump.credentials(for: host, savedHosts: SavedHostsStore.shared.hosts),
            passwordHint: "Needed to start the tunnel.")
        if let broker {
            proc.environment = ProcessInfo.processInfo.environment.merging(broker.environment) { _, new in new }
        }

        let label = forward.name.isEmpty
            ? "\(forward.listenPort) → \(host.displayLabel):\(forward.destinationPort)"
            : "\(forward.name) (\(host.displayLabel))"
        let tunnel = Tunnel(process: proc, forward: forward, host: host, broker: broker, label: label)
        let id = forward.id
        // Read stderr live: "Authenticated to …" is how we know the tunnel is up.
        // DispatchQueue.main keeps chunks and the exit in arrival order.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(bytes: handle.availableData, encoding: .utf8) ?? ""
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tunnelPrinted(id, text) } }
        }
        proc.terminationHandler = { process in
            errPipe.fileHandleForReading.readabilityHandler = nil
            let rest = (try? errPipe.fileHandleForReading.readToEnd()).flatMap { $0 }
                .flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.tunnelPrinted(id, rest)
                    self.tunnelDidExit(id, status: status)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            broker?.stop()
            errors[forward.id] = "Couldn't launch ssh: \(error.localizedDescription)"
            SarvNotifications.shared.notify(.tunnelFailed(label: label, reason: error.localizedDescription))
            return
        }
        tunnels[forward.id] = tunnel
        running.insert(forward.id)
    }

    /// Collect ssh's output; once it logged in, wait a moment (a busy port
    /// makes it exit right after) and then tell the user the tunnel is up.
    private func tunnelPrinted(_ id: UUID, _ text: String) {
        guard let tunnel = tunnels[id], !text.isEmpty else { return }
        tunnel.stderr = String((tunnel.stderr + text).suffix(Self.stderrLimit))
        guard !tunnel.loggedIn, PortForwardPlan.hasAuthenticated(tunnel.stderr) else { return }
        tunnel.loggedIn = true
        DispatchQueue.main.asyncAfter(deadline: .now() + PortForwardPlan.settleDelay) {
            MainActor.assumeIsolated {
                guard self.tunnels[id] === tunnel, tunnel.process.isRunning, !tunnel.manualStop else { return }
                self.announceRunning(tunnel)
            }
        }
    }

    private func announceRunning(_ tunnel: Tunnel) {
        tunnel.announced = true
        let message = PortForwardPlan.successMessage(for: tunnel.forward, host: tunnel.host)
        Task {
            _ = await SarvAlert.present(
                title: "Tunnel Running", message: message,
                buttons: [SarvAlert.Button("OK", isDefault: true)],
                copyableText: PortForwardPlan.localAddress(for: tunnel.forward))
        }
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

    private func tunnelDidExit(_ id: UUID, status: Int32) {
        guard let tunnel = tunnels[id] else { return }
        running.remove(id)
        tunnels[id] = nil
        tunnel.broker?.stop()
        // A manual stop, a clean exit, or the user cancelling a prompt isn't an error.
        guard !tunnel.manualStop, status != 0, tunnel.broker?.userCancelled != true else { return }
        let reason = PortForwardPlan.failureReason(stderr: tunnel.stderr, status: status, forward: tunnel.forward)
        errors[id] = reason
        // Logged in and later exited: it dropped. Never came up: it failed to start.
        let wasUp = tunnel.announced
        SarvNotifications.shared.notify(wasUp
            ? .tunnelDropped(label: tunnel.label)
            : .tunnelFailed(label: tunnel.label, reason: reason))
        if !wasUp { offerRetry(tunnel, reason: reason) }
    }

    private func offerRetry(_ tunnel: Tunnel, reason: String) {
        Task {
            let result = await SarvAlert.present(
                title: "Couldn't Start Tunnel",
                message: "\(tunnel.label)\n\n\(reason)",
                buttons: [SarvAlert.Button("Try Again", isDefault: true),
                          SarvAlert.Button("Close", isCancel: true)])
            if result.buttonIndex == 0 { start(tunnel.forward) }
        }
    }
}
