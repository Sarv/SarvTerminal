import Darwin
import Foundation

/// Finds the exact session an agent process has open by reading the agent's
/// own per-process records. The I/O edge for agent resume: every reader
/// either proves the id for THIS pid or reports `.unknown` — never a guess
/// such as "the newest session in this folder".
struct AgentSessionLocator {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    func evidence(for kind: AgentKind, processes: [RunningProcess]) -> AgentSessionEvidence {
        switch kind {
        case .claude: firstKnown(processes) { claude(pid: $0.pid) }
        case .codex: firstKnown(processes) { codex(pid: $0.pid) }
        case .copilot: firstKnown(processes) { copilot(pid: $0.pid) }
        default: .unknown
        }
    }

    /// npm installs run a `node` wrapper whose child is the real agent, so
    /// try each process in the pane's foreground job.
    private func firstKnown(
        _ processes: [RunningProcess],
        _ read: (RunningProcess) -> AgentSessionEvidence
    ) -> AgentSessionEvidence {
        for process in processes {
            let found = read(process)
            if found != .unknown { return found }
        }
        return .unknown
    }

    // MARK: Claude Code — ~/.claude/sessions/<pid>.json

    func claude(pid: Int) -> AgentSessionEvidence {
        let file = home.appendingPathComponent(".claude/sessions/\(pid).json")
        if let data = try? Data(contentsOf: file),
           let record = AgentSessionRecords.claudeRecord(data, pid: pid) {
            return hasClaudeTranscript(record) ? .session(record.sessionID) : .none
        }
        return claudeFromChildren(pid: pid)
    }

    /// Fallback when Claude wrote no per-pid record (e.g. a session started
    /// from inside another Claude): Claude sets `CLAUDE_CODE_SESSION_ID` on
    /// every process it spawns, and long-lived children (MCP servers) keep it.
    private func claudeFromChildren(pid: Int) -> AgentSessionEvidence {
        let inherited = RunningProcessReader.environment(pid: pid)
        let children = RunningProcessReader.childPIDs(of: pid).map(RunningProcessReader.environment)
        guard let sessionID = AgentSessionRecords.claudeChildSessionID(inherited: inherited, children: children),
              let cwd = RunningProcessReader.workingDirectory(pid: pid) else { return .unknown }
        let record = AgentSessionRecords.ClaudeRecord(sessionID: sessionID, cwd: cwd)
        return hasClaudeTranscript(record) ? .session(sessionID) : .unknown
    }

    /// A session that was never sent a message has no transcript and can't be
    /// resumed. Look in the cwd's project folder first, then (for paths Claude
    /// shortens) in every project folder.
    private func hasClaudeTranscript(_ record: AgentSessionRecords.ClaudeRecord) -> Bool {
        let projects = home.appendingPathComponent(".claude/projects")
        let fileName = "\(record.sessionID).jsonl"
        let expected = projects.appendingPathComponent(AgentSessionRecords.claudeProjectSlug(record.cwd))
        if FileManager.default.fileExists(atPath: expected.appendingPathComponent(fileName).path) { return true }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? []
        return folders.contains {
            FileManager.default.fileExists(atPath: projects.appendingPathComponent($0).appendingPathComponent(fileName).path)
        }
    }

    // MARK: Codex — the rollout file the process holds open

    func codex(pid: Int) -> AgentSessionEvidence {
        let marker = home.appendingPathComponent(".codex/sessions").path + "/"
        let rollout = OpenFileReader.paths(pid: pid).first { $0.hasPrefix(marker) }
        return rollout.flatMap(AgentSessionRecords.codexSessionID).map { .session($0) } ?? .unknown
    }

    // MARK: Copilot — session-state/<id>/inuse.<pid>.lock

    func copilot(pid: Int) -> AgentSessionEvidence {
        let root = home.appendingPathComponent(".copilot/session-state")
        guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return .unknown }
        let lock = "inuse.\(pid).lock"
        let owners = sessions.filter {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent(lock).path)
        }
        // Exactly one session must claim this pid, else it's ambiguous.
        return owners.count == 1 ? .session(owners[0]) : .unknown
    }
}

/// Pure parsing of the agents' records, split out for testing.
enum AgentSessionRecords {
    struct ClaudeRecord: Equatable {
        let sessionID: String
        let cwd: String
    }

    /// Accept the record only when it names this pid, so a stale file left by
    /// an earlier process that had the same pid can't be trusted.
    static func claudeRecord(_ data: Data, pid: Int) -> ClaudeRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["pid"] as? Int) == pid,
              let sessionID = object["sessionId"] as? String,
              let cwd = object["cwd"] as? String else { return nil }
        return ClaudeRecord(sessionID: sessionID, cwd: cwd)
    }

    /// The session id Claude handed its children: present in exactly one
    /// distinct value, and not merely the one Claude itself inherited from a
    /// parent Claude (which children would carry too if Claude didn't set it).
    static func claudeChildSessionID(inherited: [String: String], children: [[String: String]]) -> String? {
        let key = "CLAUDE_CODE_SESSION_ID"
        let own = inherited[key]
        let ids = Set(children.compactMap { $0[key] }.filter { $0 != own })
        return ids.count == 1 ? ids.first : nil
    }

    /// Claude stores transcripts under the cwd with every character other
    /// than a letter, digit or `-` turned into `-`.
    static func claudeProjectSlug(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : "-" })
    }

    /// `rollout-2026-11-18T10-22-05-<uuid>.jsonl` (optionally `<uuid>_<n>`)
    /// → the uuid, which is the thread id `codex resume` takes.
    static func codexSessionID(_ path: String) -> String? {
        let name = PaneCommandLine.basename(path)
        guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { return nil }
        let uuid = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
        return name.matches(of: uuid).last.map { String($0.output) }
    }
}

/// The vnode paths a process has open (libproc).
enum OpenFileReader {
    static func paths(pid: Int) -> [String] {
        let bufferSize = proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let used = proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard used > 0 else { return [] }
        return fds.prefix(Int(used) / stride)
            .filter { $0.proc_fdtype == PROX_FDTYPE_VNODE }
            .compactMap { path(pid: pid, fd: $0.proc_fd) }
    }

    private static func path(pid: Int, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(Int32(pid), fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
        }
        return path?.isEmpty == false ? path : nil
    }
}
