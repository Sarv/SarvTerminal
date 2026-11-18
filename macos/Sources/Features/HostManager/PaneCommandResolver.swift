import Foundation

/// What to put back in a pane on reopen, and where to start its shell.
struct PaneCapture: Equatable {
    let command: SavedSession.RestoreCommand
    let workingDirectory: String?
}

/// Decides what a pane's foreground job should become on reopen. Pure: the
/// agent-record lookup is injected, so every rule is unit-testable.
enum PaneCommandResolver {
    typealias EvidenceLookup = (AgentKind, [RunningProcess]) -> AgentSessionEvidence

    /// - Parameter job: the foreground process-group leader first, then its
    ///   descendants. Empty or a bare shell means the pane is idle → nil.
    static func resolve(job rawJob: [RunningProcess], evidence: EvidenceLookup) -> PaneCapture? {
        // Undo process-title rewrites first, so "npm exec @openai/codex" reads
        // as npm (its wrapper), not as a program named "codex".
        let job = normalized(rawJob)
        guard let leader = job.first, !PaneCommandLine.isShell(leader.argv.first ?? "") else { return nil }

        // An agent anywhere in the job (the leader may be a `node` wrapper or
        // `npx`) is resumed; its own process gives the argv and cwd.
        if let (kind, agent) = firstAgent(in: job) {
            let found = evidence(kind, Array(job.drop(while: { $0.pid != agent.pid })))
            let command = AgentResumeRules.restoreCommand(kind: kind, argv: agent.argv, evidence: found)
            return safe(command, cwd: agent.workingDirectory ?? leader.workingDirectory)
        }

        guard let line = PaneCommandLine.replay(leader.argv) else { return nil }
        return safe(.init(commandLine: line), cwd: leader.workingDirectory)
    }

    /// The agent in a pane's job and the pids its session file may be keyed
    /// by, so a change to that file can be traced back to the pane.
    static func trackedAgent(in rawJob: [RunningProcess]) -> TrackedAgent? {
        let job = normalized(rawJob)
        guard let leader = job.first, !PaneCommandLine.isShell(leader.argv.first ?? ""),
              let (kind, agent) = firstAgent(in: job) else { return nil }
        return TrackedAgent(kind: kind, pids: Set(job.drop(while: { $0.pid != agent.pid }).map(\.pid)))
    }

    private static func normalized(_ job: [RunningProcess]) -> [RunningProcess] {
        job.map {
            RunningProcess(pid: $0.pid, argv: PaneCommandLine.normalized($0.argv), workingDirectory: $0.workingDirectory)
        }
    }

    static func firstAgent(in job: [RunningProcess]) -> (AgentKind, RunningProcess)? {
        for process in job {
            if let kind = AgentKind.detect(process.argv) { return (kind, process) }
        }
        return nil
    }

    /// Never type a line holding control characters: Return or Ctrl-U would
    /// act as they're typed, before the shell sees any quoting.
    private static func safe(_ command: SavedSession.RestoreCommand, cwd: String?) -> PaneCapture? {
        guard !command.commandLine.isEmpty,
              !Ghostty.Shell.containsControlCharacters(command.commandLine) else { return nil }
        return PaneCapture(command: command, workingDirectory: cwd)
    }
}
