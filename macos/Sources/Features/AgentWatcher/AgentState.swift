import Foundation

/// What an AI coding agent in one pane is doing.
enum AgentState: Equatable, CaseIterable {
    case noAgent
    case idle
    case working
    case needsYou
    case done

    /// Higher wins when several panes share a tab: a pane waiting on the user
    /// matters more than a finished one, which matters more than a busy one.
    var urgency: Int {
        switch self {
        case .noAgent: return 0
        case .idle: return 1
        case .working: return 2
        case .done: return 3
        case .needsYou: return 4
        }
    }

    var isAgent: Bool { self != .noAgent }
}

/// Which signal put a pane into needs you. Only a prompt we read off the
/// screen can later be taken back by reading the screen again.
enum AgentNeedsYouSource: Equatable {
    case screen
    case notification
    case programStatus
}

/// OSC 9;4 progress, reduced to what the watcher cares about.
enum AgentProgress: Equatable {
    case active
    case cleared
    case error
}

/// An OSC 7501 program status report.
enum AgentProgramStatus: Equatable {
    case idle
    case working
    case done
    case blocked
    case error
}

/// One signal from a pane, fed to `AgentStateReducer`.
enum AgentEvent: Equatable {
    case progress(AgentProgress)
    case title(String)
    case notification(String)
    case programStatus(AgentProgramStatus)
    /// The last lines of the pane's active screen area.
    case screenSample(String)
    /// What runs in the foreground, or nil when it can't be read.
    case foreground(AgentForeground?)
    /// The pane's tab is on screen while the app is active. A done pane
    /// turns idle only once it has been done for `doneHold` seconds.
    case viewed(doneHold: TimeInterval)
    case tick
}

/// What the reducer asks the edges to do.
enum AgentEffect: Equatable {
    /// The pane just started needing the user: banner once.
    case notify
    /// The pane still needs the user: replace the banner with a reminder.
    case remind
}

struct AgentPaneState: Equatable {
    var state: AgentState = .noAgent
    /// When `state` last changed.
    var since: Date
    /// When the last notify or remind effect fired for this needs-you episode.
    var lastNotifiedAt: Date?
    /// Last `OSC 9;4` activity or spinner title, for expiring a stale working.
    var lastActivityAt: Date?
    /// The last progress report was a clear, so a plain title now means exit.
    var progressCleared = false
    /// The last title carried an agent glyph (spinner or ✳).
    var titleHasAgentGlyph = false
    var needsYouSource: AgentNeedsYouSource?
    /// A screen-sourced prompt has been seen at least once this episode.
    var promptSeenOnScreen = false

    init(since: Date) {
        self.since = since
    }
}
