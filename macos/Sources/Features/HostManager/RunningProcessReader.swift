import Darwin
import Foundation

/// What a pane's foreground process looked like at save time: enough to
/// replay it (`argv`, `workingDirectory`) or resume it (`pid` keys agent
/// session files such as `~/.claude/sessions/<pid>.json`).
struct RunningProcess: Equatable {
    let pid: Int
    /// Full argument vector as the kernel holds it (argv[0] included).
    let argv: [String]
    /// The process's current working directory, when readable.
    let workingDirectory: String?
}

/// Reads another process's argv and cwd through the kernel. This is the I/O
/// edge for pane-command capture; everything that interprets the result is
/// pure (`PaneCommandResolver`).
enum RunningProcessReader {
    static func read(pid: Int) -> RunningProcess? {
        guard pid > 0, let argv = arguments(pid: pid), !argv.isEmpty else { return nil }
        return RunningProcess(pid: pid, argv: argv, workingDirectory: workingDirectory(pid: pid))
    }

    /// The pane's foreground job: the process-group leader first, then its
    /// descendants (breadth-first, capped), since agents installed with npm
    /// run as a `node` wrapper around the real agent process.
    static func job(leaderPID: Int, limit: Int = 16) -> [RunningProcess] {
        guard let leader = read(pid: leaderPID) else { return [] }
        var job = [leader]
        var queue = [leaderPID]
        while !queue.isEmpty, job.count < limit {
            let parent = queue.removeFirst()
            for child in childPIDs(of: parent) where job.count < limit {
                guard let process = read(pid: child) else { continue }
                job.append(process)
                queue.append(child)
            }
        }
        return job
    }

    static func childPIDs(of pid: Int) -> [Int] {
        let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), nil, 0)
        guard bytes > 0 else { return [] }
        // Room for children spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 8)
        let used = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), &pids,
                                 Int32(pids.count * MemoryLayout<pid_t>.size))
        guard used > 0 else { return [] }
        return pids.prefix(Int(used) / MemoryLayout<pid_t>.size).filter { $0 > 0 }.map(Int.init)
    }

    /// The name a process was launched as. The kernel's `proc_name` is the
    /// executable file's basename, which for versioned installs is the version
    /// (Claude Code's native installer runs `~/.local/bin/claude` →
    /// `versions/2.1.328`, so `proc_name` says `2.1.328`). Then the name it
    /// was started under, argv[0], is the meaningful one. Pure.
    static func launchName(execName: String, argv0: String?) -> String {
        guard isVersionNumber(execName), let argv0 else { return execName }
        let base = (argv0 as NSString).lastPathComponent
        let name = base.hasPrefix("-") ? String(base.dropFirst()) : base
        return name.isEmpty ? execName : name
    }

    /// `2.1.328`, `1.0` — digits and dots only, starting with a digit.
    static func isVersionNumber(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isNumber else { return false }
        return name.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == "." }
    }

    /// argv via `KERN_PROCARGS2`.
    static func arguments(pid: Int) -> [String]? {
        procArgs(pid: pid).map(\.argv)
    }

    /// The environment the process was started with (`KERN_PROCARGS2`). It is
    /// a launch-time snapshot: later `setenv` calls inside it don't show.
    static func environment(pid: Int) -> [String: String] {
        procArgs(pid: pid).map { environmentDictionary($0.environment) } ?? [:]
    }

    private static func procArgs(pid: Int) -> (argv: [String], environment: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Pure parser for a `KERN_PROCARGS2` buffer. Layout: `int argc`, the exec
    /// path, NUL padding, `argc` NUL-terminated arguments, then the
    /// NUL-terminated environment.
    static func parseProcArgs(_ bytes: [UInt8]) -> (argv: [String], environment: [String])? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let argc = bytes.prefix(countSize).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }
        var cursor = countSize
        // Skip the exec path and the NUL padding after it.
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var strings: [String] = []
        while cursor < bytes.count {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            // An empty string after argv ends the environment block.
            if start == cursor, strings.count >= argc { break }
            // Strict: a line with an undecodable argument can't be retyped faithfully.
            guard let string = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
            strings.append(string)
            cursor += 1
        }
        guard strings.count >= argc else { return nil }
        return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
    }

    static func environmentDictionary(_ entries: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return result
    }

    static func workingDirectory(pid: Int) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(bytes: raw.prefix { $0 != 0 }, encoding: .utf8)
        }
        return path?.isEmpty == false ? path : nil
    }
}
