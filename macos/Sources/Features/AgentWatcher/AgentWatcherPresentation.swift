import Foundation

/// One tab as the watcher sees it, gathered at the edge from the tabs model.
struct AgentWatcherTabInput: Equatable {
    struct Pane: Equatable {
        let surfaceID: UUID
        let name: String
    }

    let tabID: UUID
    let name: String
    let panes: [Pane]
}

/// One agent pane listed under its tab when the tab holds several agents.
struct AgentWatcherPaneRow: Equatable, Identifiable {
    let surfaceID: UUID
    let name: String
    let state: AgentState
    let since: Date

    var id: UUID { surfaceID }
}

/// One agent tab in the watcher popover.
struct AgentWatcherRow: Equatable, Identifiable {
    let tabID: UUID
    /// 1-based tab position, the same number as the tab's ⌘N shortcut.
    let position: Int
    let name: String
    let state: AgentState
    let since: Date
    /// Filled only when the tab has more than one agent pane.
    let panes: [AgentWatcherPaneRow]

    var id: UUID { tabID }
}

/// The popover's content: agent tabs in position order, plus how many tabs
/// run no agent.
struct AgentWatcherList: Equatable {
    let rows: [AgentWatcherRow]
    let tabsWithoutAgent: Int
}

/// How the watcher icon looks.
struct AgentWatcherSummary: Equatable {
    /// Tabs whose agent needs the user; shown as a badge when above 0.
    let needsYouCount: Int
    /// The icon pulses while a tab needs the user.
    let pulses: Bool
    /// The icon is tinted orange without pulsing (needs you, Reduce Motion on).
    let alertTint: Bool
    /// The icon is tinted while agents work and none needs the user.
    let workingTint: Bool
    /// The icon breathes slowly while agents work, a calmer motion than
    /// the needs-you pulse. Off with Reduce Motion.
    var breathes = false
}

/// The colour of a tab chip's state dot.
enum AgentDotColor: Equatable {
    case orange
    case blue
    case green
}

/// A tab chip's state dot with the words that explain it.
struct AgentChipDot: Equatable {
    let color: AgentDotColor
    let label: String
}

/// Pure presentation rules for the watcher icon, popover and tab dots.
enum AgentWatcherPresentation {
    /// Agent tabs in tab position order. A tab's state is its most urgent
    /// pane; `since` comes from that pane.
    static func rows(tabs: [AgentWatcherTabInput], panes: [UUID: AgentPaneSnapshot]) -> AgentWatcherList {
        var rows: [AgentWatcherRow] = []
        var withoutAgent = 0
        for (index, tab) in tabs.enumerated() {
            let paneRows = tab.panes.compactMap { pane -> AgentWatcherPaneRow? in
                guard let snapshot = panes[pane.surfaceID], snapshot.state.isAgent else { return nil }
                return AgentWatcherPaneRow(
                    surfaceID: pane.surfaceID, name: pane.name, state: snapshot.state, since: snapshot.since)
            }
            guard let lead = paneRows.max(by: { $0.state.urgency < $1.state.urgency }) else {
                withoutAgent += 1
                continue
            }
            rows.append(AgentWatcherRow(
                tabID: tab.tabID, position: index + 1, name: tab.name,
                state: lead.state, since: lead.since,
                panes: paneRows.count > 1 ? paneRows : []))
        }
        return AgentWatcherList(rows: rows, tabsWithoutAgent: withoutAgent)
    }

    /// A tab's state: the most urgent of its panes.
    static func tabState(surfaceIDs: [UUID], snapshots: [UUID: AgentPaneSnapshot]) -> AgentState {
        AgentStateReducer.tabState(surfaceIDs.map { snapshots[$0]?.state ?? .noAgent })
    }

    /// The pane a jump to a tab should focus: its most urgent agent pane, the
    /// leftmost on a tie, so a split tab lands on the agent that needs the
    /// user. Nil when the tab runs no agent.
    static func leadPane(of surfaceIDs: [UUID], snapshots: [UUID: AgentPaneSnapshot]) -> UUID? {
        surfaceIDs
            .compactMap { id in snapshots[id].map { (id: id, state: $0.state) } }
            .filter { $0.state.isAgent }
            .max { $0.state.urgency < $1.state.urgency }?
            .id
    }

    /// The panes of an on-screen tab the user can see. Focus mode shows one
    /// pane (the chosen one, else the first), and a zoomed split shows only
    /// its own panes.
    static func visiblePanes(
        all: [UUID], zoomed: [UUID]?, focusMode: Bool, focusModeSurfaceID: UUID?
    ) -> Set<UUID> {
        if focusMode {
            let chosen = all.first { $0 == focusModeSurfaceID } ?? all.first
            return chosen.map { [$0] } ?? []
        }
        return Set(zoomed ?? all)
    }

    /// The name a banner gives a pane: the tab name, plus the pane name when
    /// the tab is split, so the user knows which agent asked.
    static func bannerName(tab: String, pane: String, paneCount: Int) -> String {
        paneCount > 1 && !pane.isEmpty ? "\(tab) › \(pane)" : tab
    }

    /// Needs you wins over working: a badge and a pulse, and no working tint.
    static func summary(tabStates: [AgentState], reduceMotion: Bool) -> AgentWatcherSummary {
        let needsYou = tabStates.filter { $0 == .needsYou }.count
        let working = tabStates.contains(.working)
        return AgentWatcherSummary(
            needsYouCount: needsYou,
            pulses: needsYou > 0 && !reduceMotion,
            alertTint: needsYou > 0 && reduceMotion,
            workingTint: needsYou == 0 && working,
            breathes: needsYou == 0 && working && !reduceMotion)
    }

    /// The dot on a tab chip. Agent tabs show their state, idle shows none.
    /// Tabs without an agent keep the plain attention dot.
    static func chipDot(agentState: AgentState, hasAttention: Bool) -> AgentChipDot? {
        switch agentState {
        case .needsYou: return AgentChipDot(color: .orange, label: "Agent needs you")
        case .working: return AgentChipDot(color: .blue, label: "Agent working")
        case .done: return AgentChipDot(color: .green, label: "Agent done")
        case .idle: return nil
        case .noAgent: return hasAttention ? AgentChipDot(color: .orange, label: "Needs attention") : nil
        }
    }

    /// The 0-based tab index a digit key in the popover jumps to, or nil when
    /// no tab sits at that position.
    static func tabIndex(forDigit digit: Int, tabCount: Int) -> Int? {
        guard (1...9).contains(digit), digit <= tabCount else { return nil }
        return digit - 1
    }

    /// Short time-in-state: "now", "12m", "2h 5m". Minutes only, since the
    /// popover refreshes it every 30 seconds.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "now" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    static func label(for state: AgentState) -> String {
        switch state {
        case .needsYou: return "Needs you"
        case .working: return "Working"
        case .done: return "Done"
        case .idle: return "Idle"
        case .noAgent: return "No agent"
        }
    }
}
