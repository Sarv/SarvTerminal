import Foundation

/// Remembers the last command captured per pane, so frequent session saves
/// (every title change) don't re-read every process, and so a save made while
/// processes are already gone (quit, crash teardown) keeps the last good
/// capture instead of wiping it. Entries for closed panes are pruned on every
/// save, so the cache never outgrows the open panes.
final class PaneCommandCache {
    private struct Entry {
        let pid: Int
        let capture: PaneCapture?
        let capturedAt: Date
        let agent: TrackedAgent?

        /// A plain command can't change under the same pid, and a watched
        /// agent's session switch arrives as a file event (`invalidate`).
        var maxAge: TimeInterval {
            guard let agent, !agent.hasEventSource else { return PaneCommandCache.eventDrivenMaxAge }
            return PaneCommandCache.maxAge
        }
    }

    /// How long a capture for an unchanged foreground pid stays fresh when
    /// nothing reports its changes: an unwatched agent can switch sessions
    /// without a new pid (`/clear`, `/resume`).
    static let maxAge: TimeInterval = 10
    /// The backstop for everything else, in case an event was missed.
    static let eventDrivenMaxAge: TimeInterval = 300

    private var entries: [UUID: Entry] = [:]
    private let locator: AgentSessionLocator
    private let readJob: (Int) -> [RunningProcess]

    init(locator: AgentSessionLocator = AgentSessionLocator(),
         readJob: @escaping (Int) -> [RunningProcess] = { RunningProcessReader.job(leaderPID: $0) }) {
        self.locator = locator
        self.readJob = readJob
    }

    /// The pane's restorable command. `fresh` skips the age check (used at quit).
    func capture(pane: UUID, foregroundPID: Int?, fresh: Bool, now: Date = Date()) -> PaneCapture? {
        let previous = entries[pane]
        // No pid: the pty is already closed (app quitting). Keep what we had.
        guard let pid = foregroundPID else { return previous?.capture }
        if !fresh, let previous, previous.pid == pid, now.timeIntervalSince(previous.capturedAt) < previous.maxAge {
            return previous.capture
        }
        let job = readJob(pid)
        // The process vanished between the pid read and now: keep the last capture.
        guard !job.isEmpty else { return previous?.capture }
        let locator = locator
        let capture = PaneCommandResolver.resolve(job: job) { locator.evidence(for: $0, processes: $1) }
        entries[pane] = Entry(pid: pid, capture: capture, capturedAt: now,
                              agent: PaneCommandResolver.trackedAgent(in: job))
        return capture
    }

    /// Agent panes, for routing session-file events.
    var trackedAgents: [UUID: TrackedAgent] {
        entries.compactMapValues(\.agent)
    }

    /// Force the next capture of these panes to re-read their process.
    func invalidate(panes: Set<UUID>) {
        for pane in panes {
            guard let entry = entries[pane] else { continue }
            entries[pane] = Entry(pid: entry.pid, capture: entry.capture,
                                  capturedAt: .distantPast, agent: entry.agent)
        }
    }

    func prune(keeping panes: Set<UUID>) {
        entries = entries.filter { panes.contains($0.key) }
    }

    var count: Int { entries.count }
}
