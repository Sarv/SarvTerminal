import AppKit
import SwiftUI

/// Drives a staged SSH connection by observing the terminal. The password is fed
/// to ssh out-of-band (askpass), so we only watch the terminal for success
/// (a shell prompt) or failure (an error line), and build a small in-memory log
/// of milestones + the real error — no log file on disk. Once connected we keep
/// watching for the session ending so the popup can return with Reconnect.
///
/// Runs on the main thread (poll timer on the main run loop).
final class SSHConnectionController {
    let model: SSHConnectionModel
    private weak var surfaceView: Ghostty.SurfaceView?
    private weak var tabsModel: VaultsTabsModel?

    private var timer: Timer?
    private var reconnectTimer: Timer?
    private var startTime = Date()
    private var authNoted = false

    private let pollInterval: TimeInterval = 0.2
    private let handshakeGrace: TimeInterval = 1.2
    private let optimisticTimeout: TimeInterval = 20.0
    /// Back-off schedule (seconds) for automatic reconnect attempts; the last
    /// value repeats for every attempt beyond the list.
    private let reconnectBackoff = [3, 5, 10, 15, 30]

    init(model: SSHConnectionModel,
         surfaceView: Ghostty.SurfaceView,
         tabsModel: VaultsTabsModel) {
        self.model = model
        self.surfaceView = surfaceView
        self.tabsModel = tabsModel
    }

    private var hostLabel: String { model.host.map { "\($0.hostname):\($0.port)" } ?? "server" }
    private var userLabel: String {
        let u = model.host?.username ?? ""
        return u.isEmpty ? "user" : u
    }

    // MARK: Lifecycle

    func start() {
        startTime = Date()
        authNoted = false
        model.logEntries = []
        model.addLog("network", .secondary, "Connecting to \(hostLabel)")
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func startTimer() {
        stop()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Popup actions

    func submitPassword() {
        tabsModel?.launchSSHConnection(for: model, password: model.passwordField)
    }

    func reconnect() { tabsModel?.reconnect(for: model) }
    func editHost() { tabsModel?.editHost(for: model) }

    /// Retry immediately (the "Reconnect now" button), skipping the countdown.
    func retryNow() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        model.reconnectSecondsRemaining = 0
        tabsModel?.launchSSHConnection(for: model, password: model.passwordField)
    }

    /// Stop the automatic reconnect loop (the "Stop" button); the user can still
    /// reconnect manually.
    func stopAutoReconnect() {
        model.autoReconnecting = false
        model.reconnectSecondsRemaining = 0
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: Auto-reconnect

    /// Begin (or continue) the automatic reconnect loop after a server-side /
    /// network failure. Counts down `reconnectSecondsRemaining` then relaunches.
    private func scheduleReconnect() {
        model.reconnectAttempts += 1
        model.autoReconnecting = true
        let delay = reconnectBackoff[min(model.reconnectAttempts - 1, reconnectBackoff.count - 1)]
        model.reconnectSecondsRemaining = delay
        model.addLog("arrow.clockwise", .secondary,
                     "Auto-reconnecting in \(delay)s (attempt \(model.reconnectAttempts))")
        stop()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.reconnectCountdownTick() }
        RunLoop.main.add(t, forMode: .common)
        reconnectTimer = t
    }

    private func reconnectCountdownTick() {
        guard model.autoReconnecting else {
            reconnectTimer?.invalidate(); reconnectTimer = nil; return
        }
        if model.reconnectSecondsRemaining > 1 {
            model.reconnectSecondsRemaining -= 1
            return
        }
        model.reconnectSecondsRemaining = 0
        reconnectTimer?.invalidate(); reconnectTimer = nil
        tabsModel?.launchSSHConnection(for: model, password: model.passwordField)
    }

    // MARK: Polling

    private func tick() {
        guard let sv = surfaceView else { stop(); return }

        switch model.stage {
        case .connecting:
            let text = sv.liveVisibleText()
            let lower = text.lowercased()

            if let f = failure(in: lower) {
                noteAuthenticating()
                model.addLog("xmark.octagon.fill", .red, failureLine(text) ?? f.title)
                fail(f)
                return
            }

            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > handshakeGrace { noteAuthenticating() }

            if elapsed > handshakeGrace && looksConnected(text) {
                markConnected()
                return
            }

            // Don't optimistically "connect" on timeout — a stuck connection
            // must surface an error, not silently appear successful.
            if elapsed > optimisticTimeout {
                model.addLog("xmark.octagon.fill", .red, "Timed out waiting for the session")
                fail(.timeout)
                return
            }

            if sv.childExitedMessage != nil {
                noteAuthenticating()
                model.addLog("xmark.octagon.fill", .red, "Connection closed")
                fail(.unknown("The connection closed before a session was established."))
                return
            }

        case .connected:
            if sv.childExitedMessage != nil {
                model.addLog("xmark.octagon.fill", .red, "Session closed")
                model.stage = .disconnected
                stop()
                // A dropped session (server restart, network loss) recovers on
                // its own — start the auto-reconnect loop.
                scheduleReconnect()
            }

        default:
            break
        }
    }

    private func noteAuthenticating() {
        guard !authNoted else { return }
        authNoted = true
        model.addLog("person.fill", .secondary, "Authenticating as \(userLabel)")
    }

    private func markConnected() {
        stop()
        noteAuthenticating()
        model.addLog("checkmark.circle.fill", .green, "Authenticated")
        model.addLog("checkmark.circle.fill", .green, "Session opened")
        // A successful connect clears any auto-reconnect back-off so a later drop
        // starts counting from the shortest interval again.
        model.autoReconnecting = false
        model.reconnectAttempts = 0
        model.reconnectSecondsRemaining = 0
        tabsModel?.connectionDidConnect(for: model)
        // Keep watching for the session ending (no log reset).
        startTimer()
    }

    private func fail(_ failure: SSHFailure) {
        stop()
        // Only "Ask" hosts re-prompt in the field (prefilled) to correct a
        // rejected password, up to `maxPasswordAttempts` tries; then they show
        // the failure card. "Password" hosts NEVER prompt inline — a rejected
        // saved password goes straight to the failure card (fix via Edit host).
        if failure == .permissionDenied, model.host?.authMethod == .ask {
            model.passwordAttempts += 1
            model.addLog("number.circle", .secondary,
                         "Attempt \(model.passwordAttempts) of \(model.maxPasswordAttempts) failed")
            if model.passwordAttempts < model.maxPasswordAttempts {
                model.silent = false
                model.stage = .needsPassword
                return
            }
        }
        model.stage = .failed(failure)
        // Server-side / network failures (refused, timeout, unreachable, dropped
        // handshake) recover on their own — auto-retry at increasing intervals.
        // Auth / host-key failures need the user, so we leave the card as-is.
        if failure.isAutoRetriable {
            scheduleReconnect()
        }
    }

    // MARK: Heuristics

    private func failure(in lower: String) -> SSHFailure? {
        if lower.contains("permission denied") { return .permissionDenied }
        if lower.contains("connection refused") { return .connectionRefused }
        if lower.contains("could not resolve hostname")
            || lower.contains("name or service not known")
            || lower.contains("nodename nor servname") { return .hostUnreachable }
        if lower.contains("connection timed out")
            || lower.contains("operation timed out")
            || lower.contains("connection timeout") { return .timeout }
        if lower.contains("host key verification failed") { return .hostKeyVerification }
        if lower.contains("not allowed at this time") {
            return .unknown("The server refused the connection (\"Not allowed at this time\") — it may be rate-limiting. Try again shortly.")
        }
        if lower.contains("kex_exchange_identification") || lower.contains("closed by remote host")
            || lower.contains("connection closed by") {
            return .unknown("The server closed the connection during the handshake.")
        }
        return nil
    }

    /// The actual terminal line describing the failure (for the log panel).
    private func failureLine(_ text: String) -> String? {
        let keys = ["permission denied", "connection refused", "could not resolve",
                    "name or service not known", "connection timed out", "operation timed out",
                    "host key verification failed", "not allowed at this time",
                    "connection closed", "closed by remote host"]
        for raw in text.split(separator: "\n").reversed() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let l = line.lowercased()
            if keys.contains(where: { l.contains($0) }) { return line }
        }
        return nil
    }

    /// Best-effort "we reached a shell" check: the last non-empty line looks
    /// like a shell prompt.
    private func looksConnected(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return false }
        return last.hasSuffix("$") || last.hasSuffix("#")
            || last.hasSuffix("%") || last.hasSuffix("❯") || last.hasSuffix(">")
    }
}
