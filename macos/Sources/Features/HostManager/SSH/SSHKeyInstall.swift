import Foundation

/// Pure planning for "Copy SSH Key to Server": which ssh arguments install a
/// public key into a host's `~/.ssh/authorized_keys`, how to read the result,
/// and what to tell the user. No I/O here — `SSHKeyInstaller` runs it.
enum SSHKeyInstall {
    enum Outcome: Equatable {
        case added
        case alreadyInstalled
        case failed(String)
    }

    /// Keys ssh offers without `-i` or a config entry (ssh(1) `-i`).
    static let defaultIdentityNames: Set<String> = [
        "id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_dsa",
    ]

    static let addedMarker = "SARV_KEY_ADDED"
    static let presentMarker = "SARV_KEY_PRESENT"

    /// `type base64` from a `.pub` line, or nil if it doesn't look like a key.
    static func keyBody(fromPublicKeyLine line: String) -> String? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2 else { return nil }
        let type = String(fields[0]), blob = String(fields[1])
        let typeOK = type.range(of: "^[A-Za-z0-9@.-]+$", options: .regularExpression) != nil
        let blobOK = blob.range(of: "^[A-Za-z0-9+/]+=*$", options: .regularExpression) != nil
        return typeOK && blobOK ? "\(type) \(blob)" : nil
    }

    /// Remote command: reads the full key line from stdin and appends it to
    /// authorized_keys unless a line with the same key is already there. Runs
    /// under `sh` so it works whatever the login shell is (fish, csh…). The
    /// script has no single quotes or backslashes, so wrapping it in single
    /// quotes is safe in every shell. `keyBody` is validated base64 + type.
    static func remoteCommand(keyBody: String) -> String {
        let script = [
            "umask 077",
            "mkdir -p \"$HOME/.ssh\" || exit 1",
            "F=\"$HOME/.ssh/authorized_keys\"",
            "touch \"$F\" || exit 1",
            "chmod 700 \"$HOME/.ssh\"",
            "chmod 600 \"$F\"",
            "IFS= read -r KEY || [ -n \"$KEY\" ] || exit 1",
            "if grep -qF \"\(keyBody)\" \"$F\"; then echo \(presentMarker); exit 0; fi",
            "if [ -s \"$F\" ] && [ -n \"$(tail -c 1 \"$F\")\" ]; then echo >> \"$F\"; fi",
            "echo \"$KEY\" >> \"$F\" || exit 1",
            "command -v restorecon >/dev/null 2>&1 && restorecon -F \"$HOME/.ssh\" \"$F\" >/dev/null 2>&1",
            "echo \(addedMarker)",
        ].joined(separator: "; ")
        return "exec sh -c '\(script)'"
    }

    /// Prompts (host keys, passwords for the host or a jump host) are
    /// answered by `SSHPromptBroker`, so nothing here needs BatchMode.
    static func installArgs(for host: SavedHost, keyBody: String) -> [String] {
        SSHBackgroundArgs.connection(for: host) + SSHBackgroundArgs.identity(for: host)
            + [host.sshTarget, remoteCommand(keyBody: keyBody)]
    }

    /// A login with only the new key, never prompting: success proves a plain
    /// `ssh` with that key now gets in without a password.
    /// The jump host (if any) still authenticates through the broker.
    static func verifyArgs(for host: SavedHost, privateKeyPath: String) -> [String] {
        SSHBackgroundArgs.connection(for: host) + [
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "PreferredAuthentications=publickey",
            "-i", privateKeyPath,
            host.sshTarget, "true",
        ]
    }

    static func outcome(status: Int32, stdout: String, stderr: String) -> Outcome {
        if status == 0 && stdout.contains(addedMarker) { return .added }
        if status == 0 && stdout.contains(presentMarker) { return .alreadyInstalled }
        return .failed(SSHBackgroundArgs.failureReason(stderr: stderr, status: status))
    }

    /// The plain `ssh` command the user can now run, e.g. `ssh -p 2222 root@host`.
    static func loginCommand(for host: SavedHost, keyName: String, keyPath: String) -> String {
        var parts = ["ssh"]
        if !defaultIdentityNames.contains(keyName) {
            parts += ["-i", (keyPath as NSString).abbreviatingWithTildeInPath]
        }
        if host.port != 22 { parts += ["-p", String(host.port)] }
        return (parts + [host.sshTarget]).joined(separator: " ")
    }

    /// The command itself is shown separately, in the alert's copy box.
    static func successMessage(keyName: String, outcome: Outcome,
                               verifyError: String?, target: String) -> String {
        let what = outcome == .alreadyInstalled
            ? "\(keyName) was already installed on \(target)."
            : "\(keyName) was added to \(target)."
        if let verifyError {
            return what + "\n\nBut a test login with the key failed: \(verifyError)"
        }
        let hint = defaultIdentityNames.contains(keyName)
            ? ""
            : "\n\nssh doesn't use \(keyName) unless you pass -i or add it to ~/.ssh/config."
        return what + hint + "\n\nYou can now log in without a password:"
    }
}
