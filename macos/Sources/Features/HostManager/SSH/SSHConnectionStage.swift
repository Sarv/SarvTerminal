import Foundation

/// Lifecycle of a staged SSH connection shown in the connection popup.
///
/// The password is fed to ssh out-of-band via an askpass helper (see
/// `SSHAskpass`), so there is no TTY password prompt to walk through. The popup
/// card is shown for `needsPassword` / `failed` / `disconnected`, and (for an
/// interactive attempt) `connecting`; it's hidden while `connected` so the live
/// terminal shows. For an SSH tab the card always returns on disconnect — we
/// never leave a dead terminal visible.
enum SSHConnectionStage: Equatable {
    /// Awaiting a password in the popup (host has password auth, none saved).
    case needsPassword
    /// ssh is launching/authenticating.
    case connecting
    /// Authenticated — the live terminal is shown, popup hidden.
    case connected
    /// The connection attempt failed.
    case failed(SSHFailure)
    /// The session ended after having been connected (offer reconnect).
    case disconnected
}

/// Status of a single row in the connection progress checklist.
enum SSHStepStatus {
    case pending, inProgress, success, failure
}

/// A classified SSH connection failure with user-facing copy.
enum SSHFailure: Equatable {
    case permissionDenied
    case connectionRefused
    case hostUnreachable
    case timeout
    case hostKeyVerification
    case unknown(String)

    var title: String {
        switch self {
        case .permissionDenied:    return "Authentication failed"
        case .connectionRefused:   return "Connection refused"
        case .hostUnreachable:     return "Host not found"
        case .timeout:             return "Connection timed out"
        case .hostKeyVerification: return "Host key verification failed"
        case .unknown:             return "Connection failed"
        }
    }

    var detail: String {
        switch self {
        case .permissionDenied:    return "The server rejected the password. Check it and try again."
        case .connectionRefused:   return "Nothing is listening on that host and port."
        case .hostUnreachable:     return "Could not resolve the hostname."
        case .timeout:             return "The server did not respond in time."
        case .hostKeyVerification: return "The host key did not match the previously stored value."
        case .unknown(let s):      return s
        }
    }

    /// Whether this failure is worth auto-retrying. Server-side / network issues
    /// (a restart, a refused/timed-out/unreachable host, a dropped handshake)
    /// recover on their own, so we retry at intervals. Auth and host-key failures
    /// need the user to fix something, so we don't.
    var isAutoRetriable: Bool {
        switch self {
        case .connectionRefused, .hostUnreachable, .timeout, .unknown: return true
        case .permissionDenied, .hostKeyVerification: return false
        }
    }
}
