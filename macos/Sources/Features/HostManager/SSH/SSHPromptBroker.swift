import Foundation

/// Answers the questions a background (or jump-host) ssh asks, in the app
/// instead of a terminal. ssh runs with `SSH_ASKPASS_REQUIRE=force` and the
/// interactive helper (`SSHAskpass.interactiveHelperPath`), which drops each
/// prompt into a private temp directory; the broker answers it:
/// - host-key question (any hop) → "Trust host?" alert with the fingerprint;
/// - password → a saved one for that user@host (target or jump host), asked
///   once in a secure alert otherwise, and reused for later runs of the same
///   flow (e.g. install then verify);
/// - anything else → shown as ssh wrote it, with a secure field.
/// A saved or typed password that ssh asks for again (same ssh process) was
/// rejected, so the user is asked instead of it being replayed.
@MainActor
final class SSHPromptBroker {
    private struct Request {
        let id: String
        let requester: String   // pid of the ssh that asked
        let text: String
    }

    /// Set when the user pressed Cancel on any prompt, so the caller can skip
    /// its "couldn't connect" error: the failure is the user's own choice.
    private(set) var userCancelled = false
    /// A dialog is open, waiting on the user (callers pause their timeouts).
    private(set) var isAskingUser = false

    private let directory: URL
    private let passwordHint: String
    private var credentials: [SSHCredential]
    /// "pid|user@host" already answered automatically: asked again = rejected.
    private var answered: Set<String> = []
    private var seen: Set<String> = []
    private var pending: [Request] = []
    private var busy = false
    private var watcher: DispatchSourceFileSystemObject?

    /// nil when the helper or the temp directory can't be created; callers
    /// then run ssh without askpass and report its error.
    init?(credentials: [SSHCredential], passwordHint: String) {
        guard SSHAskpass.interactiveHelperPath != nil else { return nil }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarv-prompt-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        self.directory = dir
        self.credentials = credentials
        self.passwordHint = passwordHint
        startWatching()
    }

    /// Environment that routes every ssh prompt to this broker.
    var environment: [String: String] {
        guard let helper = SSHAskpass.interactiveHelperPath else { return [:] }
        return ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", "SARV_PROMPT_DIR": directory.path]
    }

    /// Stop answering and remove the directory (a waiting helper then exits 1).
    func stop() {
        watcher?.cancel()
        watcher = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Watching

    private func startWatching() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.collectRequests() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func collectRequests() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasSuffix(".req") && !seen.contains(name) {
            seen.insert(name)
            let url = directory.appendingPathComponent(name)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: url)
            let parts = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            pending.append(Request(id: String(name.dropLast(".req".count)),
                                   requester: parts.first.map(String.init) ?? "",
                                   text: parts.count > 1 ? String(parts[1]) : ""))
        }
        answerNext()
    }

    /// One dialog at a time, in arrival order.
    private func answerNext() {
        guard !busy, !pending.isEmpty else { return }
        busy = true
        let request = pending.removeFirst()
        Task { @MainActor in
            let answer = await answer(request)
            if answer == nil { userCancelled = true }
            reply(answer, to: request)
            busy = false
            answerNext()
        }
    }

    private func reply(_ answer: String?, to request: Request) {
        let body = answer.map { "OK\n\($0)\n" } ?? "CANCEL\n\n"
        let temp = directory.appendingPathComponent("\(request.id).resp.tmp")
        let final = directory.appendingPathComponent("\(request.id).resp")
        guard (try? Data(body.utf8).write(to: temp)) != nil else { return }
        try? FileManager.default.moveItem(at: temp, to: final)
    }

    // MARK: - Answers

    private func answer(_ request: Request) async -> String? {
        let prompt = SSHPrompt.parse(request.text)
        switch prompt {
        case .hostKey(let host, let detail):
            return await trust(host: host, detail: detail) ? "yes" : nil
        case .password(let user, let host):
            let key = "\(request.requester)|\(user)@\(host)"
            if !answered.contains(key), let saved = SSHCredential.answer(for: prompt, from: credentials) {
                answered.insert(key)
                return saved
            }
            let rejected = answered.contains(key)
            answered.insert(key)
            guard let typed = await askSecret(
                title: "Password for \(user.isEmpty ? host : "\(user)@\(host)")",
                message: rejected ? "That password didn't work. Try again." : passwordHint) else { return nil }
            credentials.removeAll { $0.matches(user: user, host: host) }
            credentials.append(SSHCredential(user: user, host: host, password: typed))
            return typed
        case .other(let text):
            return await askSecret(title: "SSH Needs an Answer", message: text)
        }
    }

    private func trust(host: String, detail: String) async -> Bool {
        isAskingUser = true
        defer { isAskingUser = false }
        let result = await SarvAlert.present(
            title: host.isEmpty ? "Trust This Host?" : "Trust \(host)?",
            message: "This host isn't in your known hosts yet.\n\n\(detail)",
            buttons: [SarvAlert.Button("Trust and Continue", isDefault: true),
                      SarvAlert.Button("Cancel", isCancel: true)])
        return result.buttonIndex == 0
    }

    private func askSecret(title: String, message: String) async -> String? {
        isAskingUser = true
        defer { isAskingUser = false }
        let result = await SarvAlert.present(
            title: title, message: message,
            buttons: [SarvAlert.Button("Continue", isDefault: true),
                      SarvAlert.Button("Cancel", isCancel: true)],
            inputInitial: "", inputSecure: true)
        guard result.buttonIndex == 0, !result.inputText.isEmpty else { return nil }
        return result.inputText
    }
}
