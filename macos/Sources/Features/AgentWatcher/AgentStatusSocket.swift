import Darwin
import Foundation

/// The Unix socket agent hooks report to when the agent runs them without a
/// terminal (Codex, Gemini CLI, Copilot, Cursor, Droid, Qwen). Each hook
/// connects, sends one `AgentStatusMessage` line and disconnects.
final class AgentStatusSocket: @unchecked Sendable {
    /// `sun_path` holds 104 bytes including the terminating NUL.
    static let maxPathBytes = 103
    /// The longest line read from one client.
    static let maxLineBytes = 512

    /// This app's socket: per process, so a dev build and the installed app
    /// each get their own, in the per-user temporary folder.
    static let path = path(temporaryDirectory: NSTemporaryDirectory(), processID: getpid(), userID: getuid())

    /// `<tmp>/sarvterminal-agents-<pid>.sock`, or under /tmp with the user id
    /// when the temporary folder's path is too long for a socket.
    static func path(temporaryDirectory: String, processID: Int32, userID: uid_t) -> String {
        let name = "sarvterminal-agents-\(processID).sock"
        let preferred = (temporaryDirectory as NSString).appendingPathComponent(name)
        if preferred.utf8.count <= maxPathBytes { return preferred }
        return "/tmp/sarvterminal-agents-\(userID)-\(processID).sock"
    }

    /// The text before the first newline of what a client sent, or nil when
    /// it isn't UTF-8.
    static func line(from bytes: [UInt8]) -> String? {
        let end = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
        return String(bytes: bytes[..<end], encoding: .utf8)
    }

    private let path: String
    private let receive: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "com.sarv.terminal.agent-status-socket")
    private var source: DispatchSourceRead?

    init(path: String = AgentStatusSocket.path, receive: @escaping @MainActor (String) -> Void) {
        self.path = path
        self.receive = receive
    }

    /// Binds and starts accepting. Safe to call more than once.
    func start() throws {
        guard source == nil else { return }
        Self.removeStaleSockets(in: (path as NSString).deletingLastPathComponent)
        let listener = try Self.listen(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: listener) }
        source.setCancelHandler { close(listener) }
        source.resume()
        self.source = source
    }

    /// Stops accepting and removes the socket file. Safe to call more than once.
    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        // Here, not in the cancel handler, so a quick restart's new socket
        // file isn't removed by the old listener's late cleanup.
        unlink(path)
    }

    /// The process id in one of our socket names, or nil for any other file.
    static func processID(inSocketName name: String) -> Int32? {
        guard name.hasPrefix("sarvterminal-agents-"), name.hasSuffix(".sock") else { return nil }
        let middle = name.dropFirst("sarvterminal-agents-".count).dropLast(".sock".count)
        return middle.split(separator: "-").last.flatMap { Int32($0) }
    }

    /// Removes sockets left by app processes that quit without cleaning up.
    private static func removeStaleSockets(in directory: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in names {
            guard let processID = processID(inSocketName: name),
                  kill(processID, 0) != 0, errno == ESRCH
            else { continue }
            unlink((directory as NSString).appendingPathComponent(name))
        }
    }

    // MARK: - POSIX

    private static func posixError(_ call: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "\(call): \(String(cString: strerror(errno)))"])
    }

    /// A non-blocking listening socket at `path`, readable only by this user.
    private static func listen(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG),
                          userInfo: [NSLocalizedDescriptionKey: "Socket path too long: \(path)"])
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw posixError("socket") }
        // Shells and agents started from the app must not inherit the listener.
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        unlink(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(listener, 16) == 0,
              fcntl(listener, F_SETFL, O_NONBLOCK) == 0
        else {
            let error = posixError("bind")
            close(listener)
            unlink(path)
            throw error
        }
        return listener
    }

    private func acceptPending(on listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.serve(client)
            }
        }
    }

    /// Reads one line from a client of the same user, then closes it.
    private func serve(_ client: Int32) {
        defer { close(client) }
        var peerUser: uid_t = 0
        var peerGroup: gid_t = 0
        guard getpeereid(client, &peerUser, &peerGroup) == 0, peerUser == getuid() else { return }
        // An accepted socket inherits the listener's O_NONBLOCK on macOS.
        let flags = fcntl(client, F_GETFL)
        _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var received: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: Self.maxLineBytes)
        while received.count < Self.maxLineBytes, !received.contains(0x0A) {
            let count = read(client, &chunk, Self.maxLineBytes - received.count)
            guard count > 0 else { break }
            received += chunk[..<count]
        }
        guard let line = Self.line(from: received) else { return }
        let receive = receive
        Task { @MainActor in receive(line) }
    }
}
