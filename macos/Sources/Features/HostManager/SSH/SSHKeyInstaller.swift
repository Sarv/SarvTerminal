import Foundation

/// Runs "Copy SSH Key to Server" in the background: installs the key with a
/// plain `ssh` (host-key and password questions, for the host or a jump host,
/// answered by `SSHPromptBroker`), checks that a key-only login works, and
/// reports the result in a SarvAlert. No terminal tab is opened.
@MainActor
enum SSHKeyInstaller {
    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Longest an install or verify run may take before it is stopped. Long
    /// enough for the user to answer the trust and password prompts.
    private static let runTimeout: TimeInterval = 300

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
        let broker = SSHPromptBroker(
            credentials: SSHJump.credentials(for: host, savedHosts: SavedHostsStore.shared.hosts),
            passwordHint: "Needed once to add your key. After that, logins won't ask for it.")
        defer { broker?.stop() }
        let environment = broker?.environment ?? [:]

        let result = await runSSH(
            SSHKeyInstall.installArgs(for: host, keyBody: keyBody),
            environment: environment,
            stdin: publicLine.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        let outcome = SSHKeyInstall.outcome(
            status: result.status, stdout: result.stdout, stderr: result.stderr)

        if case .failed(let reason) = outcome {
            if broker?.userCancelled != true {
                await showError(reason, retry: { install(key, on: host) })
            }
            return
        }

        let verify = await runSSH(
            SSHKeyInstall.verifyArgs(for: host, privateKeyPath: key.privatePath),
            environment: environment, stdin: nil)
        let verifyError = verify.status == 0
            ? nil
            : SSHBackgroundArgs.failureReason(stderr: verify.stderr, status: verify.status)
        _ = await SarvAlert.present(
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

    private static func showError(_ reason: String, retry: (() -> Void)?) async {
        var buttons = [SarvAlert.Button("OK", isDefault: retry == nil, isCancel: true)]
        if retry != nil { buttons.insert(SarvAlert.Button("Try Again", isDefault: true), at: 0) }
        let result = await SarvAlert.present(title: "Couldn't Copy SSH Key", message: reason, buttons: buttons)
        if let retry, result.buttonIndex == 0 { retry() }
    }

    // MARK: - Process

    /// Runs `/usr/bin/ssh` with no TTY off the main thread, with the broker's
    /// askpass `environment`; `stdin` (if any) is written then closed.
    private static func runSSH(_ args: [String], environment: [String: String],
                               stdin: String?) async -> RunResult {
        let timeout = runTimeout
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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
