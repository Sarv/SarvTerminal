import Foundation

/// The agent watcher's state machine for one pane. Pure: given the pane's
/// state, one signal and the time, it returns the next state and the effects
/// the caller should run. No AppKit, no timers, no notifications.
enum AgentStateReducer {
    /// Working with no progress refresh or spinner change for this long is
    /// treated as finished (the agent crashed or was killed).
    static let workingExpiry: TimeInterval = 20
    /// How often a pane that still needs the user re-notifies.
    static let reminderInterval: TimeInterval = 5 * 60

    /// Spinner glyphs agents put at the start of the title while they work.
    private static let spinnerGlyphs: Set<Character> = [
        "◐", "◓", "◑", "◒",
        "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
    ]
    /// Claude Code's idle title glyph.
    private static let idleGlyph: Character = "✳"

    /// Every agent SarvTerminal can install hooks for.
    private static let agentProcesses: Set<String> = Set(AgentHookIntegration.all.flatMap(\.processNames))
    private static let shellProcesses: Set<String> = ["zsh", "bash", "fish", "sh"]

    typealias Result = (pane: AgentPaneState, effects: [AgentEffect])

    static func reduce(_ pane: AgentPaneState, _ event: AgentEvent, now: Date) -> Result {
        switch event {
        case .progress(let progress): return progressChanged(pane, progress, now: now)
        case .title(let title): return titleChanged(pane, title, now: now)
        case .notification(let body): return notified(pane, body, now: now)
        case .programStatus(let status): return statusReported(pane, status, now: now)
        case .screenSample(let tail): return screenSampled(pane, tail, now: now)
        case .foreground(let process): return foregroundChanged(pane, process, now: now)
        case .viewed(let doneHold): return viewed(pane, doneHold: doneHold, now: now)
        case .tick: return ticked(pane, now: now)
        }
    }

    /// A tab shows the most urgent state among its panes.
    static func tabState(_ panes: [AgentState]) -> AgentState {
        panes.max(by: { $0.urgency < $1.urgency }) ?? .noAgent
    }

    // MARK: - Transitions

    private static func progressChanged(_ pane: AgentPaneState, _ progress: AgentProgress, now: Date) -> Result {
        switch progress {
        case .active:
            return (startedWorking(pane, now: now), [])
        case .cleared:
            var next = pane
            next.progressCleared = true
            if pane.state == .working { next = moved(next, to: .done, now: now) }
            return (next, [])
        case .error:
            var next = pane
            next.progressCleared = true
            return (moved(next, to: .done, now: now), [])
        }
    }

    private static func titleChanged(_ pane: AgentPaneState, _ title: String, now: Date) -> Result {
        let first = title.first
        if let first, spinnerGlyphs.contains(first) {
            var next = startedWorking(pane, now: now)
            next.titleHasAgentGlyph = true
            return (next, [])
        }
        var next = pane
        next.titleHasAgentGlyph = first == idleGlyph
        if next.titleHasAgentGlyph {
            if pane.state == .noAgent { next = moved(next, to: .idle, now: now) }
            return (next, [])
        }
        // The agent cleared its progress and then gave the title back: it exited.
        if pane.state.isAgent && pane.progressCleared {
            return (moved(next, to: .noAgent, now: now), [])
        }
        return (next, [])
    }

    private static func notified(_ pane: AgentPaneState, _ body: String, now: Date) -> Result {
        guard pane.state.isAgent,
              AgentMessageClassifier.verdict(body) == .needsYou
        else { return (pane, []) }
        return enteredNeedsYou(pane, source: .notification, now: now)
    }

    private static func statusReported(_ pane: AgentPaneState, _ status: AgentProgramStatus, now: Date) -> Result {
        switch status {
        case .working: return (startedWorking(pane, now: now), [])
        case .idle: return (moved(pane, to: .idle, now: now), [])
        case .done, .error: return (moved(pane, to: .done, now: now), [])
        case .blocked: return enteredNeedsYou(pane, source: .programStatus, now: now)
        }
    }

    private static func screenSampled(_ pane: AgentPaneState, _ tail: String, now: Date) -> Result {
        let prompt = AgentMessageClassifier.showsPrompt(tail)
        switch pane.state {
        case .done where prompt:
            var (next, effects) = enteredNeedsYou(pane, source: .screen, now: now)
            next.promptSeenOnScreen = true
            return (next, effects)
        case .needsYou where pane.needsYouSource == .screen:
            if prompt {
                var next = pane
                next.promptSeenOnScreen = true
                return (next, [])
            }
            // The user answered (or dismissed) the prompt and the agent didn't
            // start working again, e.g. a "No".
            guard pane.promptSeenOnScreen else { return (pane, []) }
            return (moved(pane, to: .idle, now: now), [])
        default:
            return (pane, [])
        }
    }

    private static func foregroundChanged(_ pane: AgentPaneState, _ process: String?, now: Date) -> Result {
        guard let name = process.map(processName) else { return (pane, []) }
        if agentProcesses.contains(name) && pane.state == .noAgent {
            return (moved(pane, to: .idle, now: now), [])
        }
        if shellProcesses.contains(name) && pane.state.isAgent && !pane.titleHasAgentGlyph {
            return (moved(pane, to: .noAgent, now: now), [])
        }
        return (pane, [])
    }

    private static func viewed(_ pane: AgentPaneState, doneHold: TimeInterval, now: Date) -> Result {
        guard pane.state == .done, now.timeIntervalSince(pane.since) >= doneHold else { return (pane, []) }
        return (moved(pane, to: .idle, now: now), [])
    }

    private static func ticked(_ pane: AgentPaneState, now: Date) -> Result {
        switch pane.state {
        case .working:
            let lastActivity = pane.lastActivityAt ?? pane.since
            guard now.timeIntervalSince(lastActivity) >= workingExpiry else { return (pane, []) }
            return (moved(pane, to: .done, now: now), [])
        case .needsYou:
            let last = pane.lastNotifiedAt ?? pane.since
            guard now.timeIntervalSince(last) >= reminderInterval else { return (pane, []) }
            var next = pane
            next.lastNotifiedAt = now
            return (next, [.remind])
        default:
            return (pane, [])
        }
    }

    // MARK: - Helpers

    private static func startedWorking(_ pane: AgentPaneState, now: Date) -> AgentPaneState {
        var next = moved(pane, to: .working, now: now)
        next.lastActivityAt = now
        next.progressCleared = false
        return next
    }

    private static func enteredNeedsYou(
        _ pane: AgentPaneState, source: AgentNeedsYouSource, now: Date
    ) -> Result {
        guard pane.state != .needsYou else { return (pane, []) }
        var next = moved(pane, to: .needsYou, now: now)
        next.needsYouSource = source
        next.lastNotifiedAt = now
        return (next, [.notify])
    }

    /// Changes the state, restarting its clock only on a real change, and
    /// drops needs-you bookkeeping when leaving needs you.
    private static func moved(_ pane: AgentPaneState, to state: AgentState, now: Date) -> AgentPaneState {
        guard pane.state != state else { return pane }
        var next = pane
        next.state = state
        next.since = now
        if state != .needsYou {
            next.needsYouSource = nil
            next.promptSeenOnScreen = false
            next.lastNotifiedAt = nil
        }
        if state == .noAgent {
            next.progressCleared = false
            next.lastActivityAt = nil
        }
        return next
    }

    /// `/usr/local/bin/claude` and `-zsh` both reduce to a bare name.
    static func processName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent.lowercased()
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }
}
