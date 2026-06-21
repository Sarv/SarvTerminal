import SwiftUI

/// One line in the connection log panel.
struct SSHLogEntry: Identifiable {
    let id = UUID()
    let symbol: String
    let color: Color
    let text: String
}

/// Observable state for an SSH connection shown in the popup over a Vaults tab.
/// Lives for the tab's lifetime so the popup can reappear (with Reconnect) when
/// the session ends — we never show a dead terminal for an SSH tab.
final class SSHConnectionModel: ObservableObject {
    /// Display name shown in the popup header (host label or target).
    let title: String
    /// The originating saved host, if any.
    let host: SavedHost?

    @Published var stage: SSHConnectionStage
    /// Password typed into the popup (prefilled from the saved host).
    @Published var passwordField: String
    @Published var passwordAttempts: Int = 0
    /// Max wrong-password tries before we give up and show the failure card.
    let maxPasswordAttempts = 3

    /// True once the user has answered the host-key trust prompt this attempt.
    @Published var hostKeyResponded = false
    /// Whether this host needs a typed password (drives the password step after
    /// the host-key step). Stable for the connection's lifetime.
    let requiresPassword: Bool
    /// Scanned known_hosts line(s) awaiting the user's trust decision.
    var scannedHostKeyLines: String?
    /// The host's known_hosts token (for add/remove). Persists across the
    /// controller being recreated on (re)launch.
    var hostKeyToken: String?
    /// When set (a "Continue" without saving), the key is removed once connected.
    var pendingHostKeyRemoval: String?

    /// Auto-reconnect (server restart / network drop): when true the popup is
    /// counting down to the next automatic retry. `reconnectSecondsRemaining`
    /// drives the "Reconnecting in Ns…" label; `reconnectAttempts` counts how
    /// many automatic attempts have been made (drives the back-off interval).
    @Published var autoReconnecting: Bool = false
    @Published var reconnectSecondsRemaining: Int = 0
    var reconnectAttempts: Int = 0

    /// True when we already have a password (saved) so the first attempt needs
    /// no field and shows no card while connecting.
    @Published var silent: Bool

    /// Curated, in-memory connection log shown in the "Show logs" panel — built
    /// from synthesized milestones and the real terminal error. No file on disk.
    @Published var logEntries: [SSHLogEntry] = []
    @Published var showLogs: Bool = false
    /// Path of the temp file holding the password for the askpass helper.
    var passwordFilePath: String?

    func addLog(_ symbol: String, _ color: Color, _ text: String) {
        logEntries.append(SSHLogEntry(symbol: symbol, color: color, text: text))
    }

    /// Plain text of the log for the "Copy logs" button.
    var logCopyText: String { logEntries.map(\.text).joined(separator: "\n") }

    init(title: String, host: SavedHost?, needsPassword: Bool) {
        self.title = title
        self.host = host
        self.requiresPassword = needsPassword
        self.passwordField = host?.password ?? ""
        self.silent = !needsPassword
        // The pre-flight host-key check sets the real first stage; start neutral.
        self.stage = .connecting
    }

    /// Whether the popup card should be visible. The card shows for the whole
    /// connection lifecycle (asking → connecting → failed/disconnected) and only
    /// hides once `connected`, so the live terminal shows. This means an SSH
    /// connect ALWAYS shows the popup (Termius-style), even when it uses a saved
    /// password and needs no field.
    var showsCard: Bool {
        if case .connected = stage { return false }
        return true
    }
}
