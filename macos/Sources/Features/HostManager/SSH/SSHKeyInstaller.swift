import Foundation

/// Runs "Copy SSH Key to Server" in the background: trusts the host key if
/// needed, gets the password (saved, or asked once), installs the key with a
/// plain `ssh`, checks that a key-only login works, and reports the result in
/// a SarvAlert. No terminal tab is opened.
@MainActor
enum SSHKeyInstaller {
    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Longest an install or verify run may take before it is stopped.
    private static let runTimeout: TimeInterval = 60

    static func install(_ key: SSHKey, on host: SavedHost) {
        Task { await run(key, on: host) }
    }

    private static func run(_ key: SSHKey, on host: SavedHost) async {
        guard let publicPath = key.publicPath,
              let publicLine = try? String(contentsOfFile: publicPath, encoding: .utf8),
              let keyBody = SSHKeyInstall.keyBody(fromPublicKeyLine: publicLine) else {
            await showError("\(key.name).pub couldn't be read as a public key.", retry: nil)
            return
        }
        guard await trustHostKeyIfNeeded(host) else { return }

        let auth = SSHKeyInstall.auth(for: host)
        var password = host.password
        if SSHKeyInstall.needsPasswordPrompt(host) {
            guard let typed = await askPassword(for: host) else { return }
            password = typed
        }

        let result = await runSSH(
            SSHKeyInstall.installArgs(for: host, auth: auth, keyBody: keyBody),
            password: auth == .password ? password : "",
            stdin: publicLine.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        let outcome = SSHKeyInstall.outcome(
            status: result.status, stdout: result.stdout, stderr: result.stderr)

        if case .failed(let reason) = outcome {
            await showError(reason, retry: { install(key, on: host) })
            return
        }

        let verify = await runSSH(
            SSHKeyInstall.verifyArgs(for: host, privateKeyPath: key.privatePath),
            password: "", stdin: nil)
        let verifyError = verify.status == 0
            ? nil
            : SSHKeyInstall.failureReason(stderr: verify.stderr, status: verify.status)
        _ = await alert(
            title: verifyError == nil ? "SSH Key Copied" : "SSH Key Copied, Login Not Confirmed",
            message: SSHKeyInstall.successMessage(
                keyName: key.name,
                outcome: outcome,
                verifyError: verifyError,
                target: host.sshTarget),
            buttons: [SarvAlert.Button("OK", isDefault: true)],
            copyableText: verifyError == nil
                ? SSHKeyInstall.loginCommand(for: host, keyName: key.name, keyPath: key.privatePath)
                : nil)
    }

    // MARK: - Prompts

    /// Same pre-flight as a guided connect: an unknown host key is shown for
    /// the user to trust before ssh runs, so ssh never has to ask.
    private static func trustHostKeyIfNeeded(_ host: SavedHost) async -> Bool {
        guard host.strictHostKeyChecking != .no else { return true }
        let token = HostKeyScanner.token(host: host.hostname, port: host.port)
        guard await HostKeyScanner.isKnown(token) == false,
              let scan = await HostKeyScanner.scan(host: host.hostname, port: host.port) else {
            return true   // known, or unreachable: ssh reports the real error
        }
        let result = await alert(
            title: "Trust \(token)?",
            message: "This host isn't in your known hosts yet.\n\n\(scan.keyType) key fingerprint:\n\(scan.fingerprint)",
            buttons: [SarvAlert.Button("Trust and Continue", isDefault: true),
                      SarvAlert.Button("Cancel", isCancel: true)])
        guard result.buttonIndex == 0 else { return false }
        HostKeyScanner.add(scan.lines)
        return true
    }

    private static func askPassword(for host: SavedHost) async -> String? {
        let result = await alert(
            title: "Password for \(host.sshTarget)",
            message: "Needed once to add your key. After that, logins won't ask for it.",
            buttons: [SarvAlert.Button("Copy Key", isDefault: true),
                      SarvAlert.Button("Cancel", isCancel: true)],
            inputInitial: "", inputSecure: true)
        guard result.buttonIndex == 0, !result.inputText.isEmpty else { return nil }
        return result.inputText
    }

    private static func showError(_ reason: String, retry: (() -> Void)?) async {
        var buttons = [SarvAlert.Button("OK", isDefault: retry == nil, isCancel: true)]
        if retry != nil { buttons.insert(SarvAlert.Button("Try Again", isDefault: true), at: 0) }
        let result = await alert(title: "Couldn't Copy SSH Key", message: reason, buttons: buttons)
        if let retry, result.buttonIndex == 0 { retry() }
    }

    private static func alert(title: String, message: String, buttons: [SarvAlert.Button],
                              inputInitial: String? = nil, inputSecure: Bool = false,
                              copyableText: String? = nil) async -> SarvAlert.Result {
        await withCheckedContinuation { continuation in
            SarvAlert.present(title: title, message: message, buttons: buttons,
                              inputInitial: inputInitial, inputSecure: inputSecure,
                              copyableText: copyableText) {
                continuation.resume(returning: $0)
            }
        }
    }

    // MARK: - Process

    /// Runs `/usr/bin/ssh` with no TTY off the main thread. A password goes
    /// through the askpass helper; `stdin` (if any) is written then closed.
    private static func runSSH(_ args: [String], password: String, stdin: String?) async -> RunResult {
        let askpass = SSHAskpass.env(forPassword: password)
        defer {
            if let file = askpass["SARV_ASKPASS_FILE"] { try? FileManager.default.removeItem(atPath: file) }
        }
        let timeout = runTimeout
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(askpass) { _, new in new }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = stdin == nil ? FileHandle.nullDevice : input
            process.standardOutput = output
            process.standardError = errors
            do { try process.run() } catch {
                return RunResult(status: -1, stdout: "", stderr: error.localizedDescription)
            }
            if let stdin {
                try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let out = (try? output.fileHandleForReading.readToEnd()) ?? Data()
            let err = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            watchdog.cancel()
            return RunResult(status: process.terminationStatus,
                             stdout: String(bytes: out, encoding: .utf8) ?? "",
                             stderr: String(bytes: err, encoding: .utf8) ?? "")
        }.value
    }
}
