import Foundation
import Testing
@testable import Ghostty

private func host(auth: SavedHost.AuthMethod = .password, port: Int = 22,
                  password: String = "", checking: SavedHost.HostKeyChecking = .ask) -> SavedHost {
    var host = SavedHost.blank(hostname: "10.0.5.40")
    host.username = "clickhouse"
    host.authMethod = auth
    host.port = port
    host.password = password
    host.strictHostKeyChecking = checking
    return host
}

private let keyBody = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOq+/x=="

@Suite
struct SSHKeyInstallTests {
    @Test func passwordIsAskedOnlyWhenNoneIsSaved() {
        #expect(SSHKeyInstall.needsPasswordPrompt(host(auth: .ask)))
        #expect(SSHKeyInstall.needsPasswordPrompt(host(auth: .password)))
        #expect(!SSHKeyInstall.needsPasswordPrompt(host(auth: .password, password: "pw")))
        #expect(!SSHKeyInstall.needsPasswordPrompt(host(auth: .agent)))
    }

    @Test func hostKeyAskBecomesAcceptNewSoSshNeverPrompts() {
        #expect(SSHKeyInstall.hostKeyPolicy(.ask) == "accept-new")
        #expect(SSHKeyInstall.hostKeyPolicy(.yes) == "yes")
        #expect(SSHKeyInstall.hostKeyPolicy(.no) == "no")
    }

    @Test func keyBodyDropsCommentAndRejectsJunk() {
        #expect(SSHKeyInstall.keyBody(fromPublicKeyLine: "\(keyBody) me@mac 'quoted'\n") == keyBody)
        #expect(SSHKeyInstall.keyBody(fromPublicKeyLine: "not-a-key") == nil)
        #expect(SSHKeyInstall.keyBody(fromPublicKeyLine: "ssh-rsa abc'def") == nil)
    }

    @Test func remoteCommandIsSingleQuoteSafe() {
        let command = SSHKeyInstall.remoteCommand(keyBody: keyBody)
        #expect(command.hasPrefix("exec sh -c '") && command.hasSuffix("'"))
        let script = command.dropFirst("exec sh -c '".count).dropLast()
        #expect(!script.contains("'") && !script.contains("\\"))
        #expect(script.contains("grep -qF \"\(keyBody)\""))
    }

    @Test func passwordInstallAllowsOnePromptAndKeyInstallNever() {
        let password = SSHKeyInstall.installArgs(for: host(port: 2222), auth: .password, keyBody: keyBody)
        #expect(password.contains("NumberOfPasswordPrompts=1"))
        #expect(!password.contains("BatchMode=yes"))
        #expect(Array(password.prefix(2)) == ["-p", "2222"])
        #expect(password.suffix(2).first == "clickhouse@10.0.5.40")

        let key = SSHKeyInstall.installArgs(
            for: host(auth: .publicKey), auth: .key(identityFile: "/k/id_x"), keyBody: keyBody)
        #expect(key.contains("BatchMode=yes"))
        #expect(key.contains("/k/id_x"))
    }

    @Test func verifyUsesOnlyTheNewKey() {
        let args = SSHKeyInstall.verifyArgs(for: host(), privateKeyPath: "/k/id_rsa")
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("BatchMode=yes"))
        #expect(Array(args.suffix(4)) == ["-i", "/k/id_rsa", "clickhouse@10.0.5.40", "true"])
    }

    @Test func outcomeReadsMarkersAndSkipsKnownHostsWarning() {
        #expect(SSHKeyInstall.outcome(status: 0, stdout: "SARV_KEY_ADDED\n", stderr: "") == .added)
        #expect(SSHKeyInstall.outcome(status: 0, stdout: "SARV_KEY_PRESENT\n", stderr: "") == .alreadyInstalled)
        let denied = "Warning: Permanently added '10.0.5.40' (ED25519)\nclickhouse@10.0.5.40: Permission denied (password).\n"
        #expect(SSHKeyInstall.outcome(status: 255, stdout: "", stderr: denied)
            == .failed("clickhouse@10.0.5.40: Permission denied (password)."))
        #expect(SSHKeyInstall.outcome(status: 1, stdout: "", stderr: "") == .failed("ssh exited with status 1."))
    }

    @Test func loginCommandAddsDashIOnlyForNonDefaultKeys() {
        let home = NSHomeDirectory()
        #expect(SSHKeyInstall.loginCommand(for: host(), keyName: "id_rsa", keyPath: "\(home)/.ssh/id_rsa")
            == "ssh clickhouse@10.0.5.40")
        #expect(SSHKeyInstall.loginCommand(for: host(port: 2222), keyName: "id_vr_dev", keyPath: "\(home)/.ssh/id_vr_dev")
            == "ssh -i ~/.ssh/id_vr_dev -p 2222 clickhouse@10.0.5.40")
    }

    @Test func successMessageExplainsResult() {
        let ok = SSHKeyInstall.successMessage(keyName: "id_rsa", outcome: .added, verifyError: nil, target: "a@b")
        #expect(ok.contains("was added to a@b") && ok.hasSuffix("without a password:") && !ok.contains("~/.ssh/config"))
        let custom = SSHKeyInstall.successMessage(keyName: "id_vr_dev", outcome: .alreadyInstalled,
                                                  verifyError: nil, target: "a@b")
        #expect(custom.contains("already installed") && custom.contains("~/.ssh/config"))
        #expect(custom.hasSuffix("without a password:"))
        let failed = SSHKeyInstall.successMessage(keyName: "id_rsa", outcome: .added,
                                                  verifyError: "denied", target: "a@b")
        #expect(failed.contains("test login with the key failed: denied"))
    }
}

/// Runs the real remote script under /bin/sh against a temp $HOME.
@Suite
struct SSHKeyInstallScriptTests {
    private func runScript(home: URL, keyLine: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHKeyInstall.remoteCommand(keyBody: keyBody)]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((keyLine + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        return String(bytes: try output.fileHandleForReading.readToEnd() ?? Data(), encoding: .utf8) ?? ""
    }

    @Test func addsOnceKeepsExistingKeysAndFixesMissingNewline() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sshDir = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = sshDir.appendingPathComponent("authorized_keys")
        try "ssh-rsa AAAAold other@host".write(to: file, atomically: true, encoding: .utf8)

        #expect(try runScript(home: home, keyLine: "\(keyBody) me@mac").contains("SARV_KEY_ADDED"))
        #expect(try runScript(home: home, keyLine: "\(keyBody) renamed").contains("SARV_KEY_PRESENT"))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content == "ssh-rsa AAAAold other@host\n\(keyBody) me@mac\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
