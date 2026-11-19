import Foundation

/// What runs in a pane's foreground, as the watcher sees it. Decided from the
/// job's argv with the same `AgentKind` rules session restore uses, so every
/// agent restore knows (native or npm-installed, where the process name is
/// just `node` or a version number) is recognised the same way.
enum AgentForeground: Equatable {
    case agent(AgentKind)
    case shell
    case other

    /// Pure. A shell never needs its job read.
    static func classify(processName: String, readJob: () -> [RunningProcess]) -> AgentForeground {
        if PaneCommandLine.isShell(processName) { return .shell }
        guard let tracked = PaneCommandResolver.trackedAgent(in: readJob()) else { return .other }
        return .agent(tracked.kind)
    }

    /// The agent's program name (`claude`, `cursor-agent`), for hook offers.
    var agentProgram: String? {
        guard case .agent(let kind) = self else { return nil }
        return kind.program
    }
}

/// Remembers each pane's classification per foreground process, so the
/// 2-second tick reads a process's argv once, not on every tick.
struct AgentForegroundCache {
    private struct Key: Equatable {
        let pid: Int
        let processName: String
    }

    private var entries: [UUID: (key: Key, foreground: AgentForeground)] = [:]

    /// Keyed by pid and name too: a shell that `exec`s an agent keeps its pid.
    mutating func foreground(pane: UUID, pid: Int, processName: String,
                             readJob: (Int) -> [RunningProcess]) -> AgentForeground {
        let key = Key(pid: pid, processName: processName)
        if let entry = entries[pane], entry.key == key { return entry.foreground }
        let foreground = AgentForeground.classify(processName: processName) { readJob(pid) }
        entries[pane] = (key, foreground)
        return foreground
    }

    mutating func prune(keeping panes: Set<UUID>) {
        entries = entries.filter { panes.contains($0.key) }
    }
}
