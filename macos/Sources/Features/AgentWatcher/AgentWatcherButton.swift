import AppKit
import SwiftUI

extension AgentDotColor {
    var color: Color {
        switch self {
        case .orange: return .orange
        case .blue: return .blue
        case .green: return .green
        }
    }
}

extension AgentState {
    /// The chip colour for a state: its tab-dot colour, or grey for idle.
    var watcherColor: Color {
        AgentWatcherPresentation.chipDot(agentState: self, hasAttention: false)?.color.color ?? .secondary
    }
}

/// The AI agent robot after the Vaults/SFTP island. Shows a needs-you badge,
/// pulses orange while a tab needs the user, breathes blue while agents
/// work, and opens the agent list.
struct AgentWatcherButton: View {
    @ObservedObject var tabs: VaultsTabsModel
    @ObservedObject private var store: AgentWatcherStore = .shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPresented = false
    @State private var pulseDimmed = false
    @State private var isHovered = false

    private var summary: AgentWatcherSummary {
        let states = tabs.terminals.map { tab in
            AgentWatcherPresentation.tabState(
                surfaceIDs: (tab.surfaceTree.root?.leaves() ?? []).map(\.id), snapshots: store.snapshots)
        }
        return AgentWatcherPresentation.summary(tabStates: states, reduceMotion: reduceMotion)
    }

    private func iconColor(_ summary: AgentWatcherSummary) -> Color {
        if summary.pulses || summary.alertTint { return .orange }
        if summary.workingTint { return .blue }
        return .secondary
    }

    private func tooltip(_ summary: AgentWatcherSummary) -> String {
        switch summary.needsYouCount {
        case 0: return summary.workingTint ? "AI Agent Watcher: agents working" : "AI Agent Watcher"
        case 1: return "AI Agent Watcher: 1 tab needs you"
        default: return "AI Agent Watcher: \(summary.needsYouCount) tabs need you"
        }
    }

    var body: some View {
        if store.isEnabled { button }
    }

    @ViewBuilder private var button: some View {
        let summary = summary
        let tooltip = tooltip(summary)
        let alerting = summary.needsYouCount > 0
        Button { isPresented.toggle() } label: {
            AIAgentGlyph()
                .frame(width: 15, height: 15)
                .foregroundStyle(iconColor(summary))
                .opacity(pulseDimmed ? dimmedOpacity(summary) : 1)
                // Same height and padding as the section pills and tab chips.
                .frame(height: 15)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillColor(alerting: alerting, working: summary.workingTint))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            borderColor(alerting: alerting, working: summary.workingTint),
                            lineWidth: isPresented ? 1.5 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if alerting {
                        Text("\(summary.needsYouCount)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange))
                            .offset(x: 5, y: -5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // No tip while the list is open: it would cover the popover.
        .hoverTip(isPresented ? "" : tooltip)
        .accessibilityLabel(tooltip)
        .onAppear { setPulse(motion(summary)) }
        .onChange(of: motion(summary)) { setPulse($0) }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AgentWatcherPopover(tabs: tabs, store: store, isPresented: $isPresented)
        }
    }

    /// Orange while a tab needs the user, blue while agents work, otherwise
    /// the section pills' grey, stronger on hover or while the list is open.
    private func fillColor(alerting: Bool, working: Bool) -> Color {
        let emphasized = isHovered || isPresented
        if alerting { return Color.orange.opacity(emphasized ? 0.26 : 0.16) }
        if working { return Color.blue.opacity(emphasized ? 0.22 : 0.12) }
        return emphasized ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)
    }

    /// The accent border marks the open list, as on the selected pill.
    private func borderColor(alerting: Bool, working: Bool) -> Color {
        if isPresented { return Color.accentColor.opacity(0.9) }
        if alerting { return Color.orange.opacity(0.55) }
        return working ? Color.blue.opacity(0.45) : .clear
    }

    /// The icon's repeating motion: a quick pulse for needs-you, a slow
    /// breath for working.
    private enum Motion: Equatable {
        case still, pulse, breathe

        var duration: TimeInterval { self == .pulse ? 0.9 : 1.6 }
    }

    private func motion(_ summary: AgentWatcherSummary) -> Motion {
        if summary.pulses { return .pulse }
        return summary.breathes ? .breathe : .still
    }

    private func dimmedOpacity(_ summary: AgentWatcherSummary) -> Double {
        motion(summary) == .pulse ? 0.35 : 0.5
    }

    /// Restarts the repeating fade for `motion`, or stops it. Resetting to
    /// undimmed first lets a pulse-to-breathe switch pick up the new speed.
    private func setPulse(_ motion: Motion) {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { pulseDimmed = false }
        guard motion != .still else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: motion.duration).repeatForever(autoreverses: true)) {
                pulseDimmed = true
            }
        }
    }
}

/// The agent list: agent tabs in position order, each jumping to its tab.
struct AgentWatcherPopover: View {
    @ObservedObject var tabs: VaultsTabsModel
    @ObservedObject var store: AgentWatcherStore
    @Binding var isPresented: Bool

    @State private var keyMonitor: Any?

    private var list: AgentWatcherList {
        AgentWatcherPresentation.rows(tabs: tabs.agentWatcherInputs(), panes: store.snapshots)
    }

    var body: some View {
        let list = list
        VStack(alignment: .leading, spacing: 4) {
            Text("AI Agents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            if list.rows.isEmpty {
                Text("No AI agents running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(list.rows) { row in
                            AgentWatcherRowView(row: row, now: context.date) { surfaceID in
                                jump(tabID: row.tabID, surfaceID: surfaceID)
                            }
                        }
                    }
                }
            }
            if list.tabsWithoutAgent > 0 {
                Divider().padding(.vertical, 2)
                Text(list.tabsWithoutAgent == 1
                     ? "1 other tab has no AI agent"
                     : "\(list.tabsWithoutAgent) other tabs have no AI agent")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiaryText)
                    .padding(.horizontal, 8)
            }
            Divider().padding(.vertical, 2)
            AIAgentsSettingsLink(isPresented: $isPresented)
        }
        .padding(8)
        .frame(width: 320)
        .onAppear(perform: installDigitKeys)
        .onDisappear(perform: removeDigitKeys)
    }

    /// Selects the tab and closes the popover. A sub-row focuses its pane;
    /// a tab row focuses the tab's most urgent agent pane.
    private func jump(tabID: UUID, surfaceID: UUID?) {
        if let surfaceID {
            tabs.focusPane(tabID: tabID, surfaceID: surfaceID)
        } else {
            tabs.focusAgentTab(tabID)
        }
        isPresented = false
    }

    /// Digits 1-9 jump to that tab position while the popover is open.
    private func installDigitKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function])
            guard modifiers.isEmpty,
                  let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                  let index = AgentWatcherPresentation.tabIndex(forDigit: digit, tabCount: tabs.terminals.count)
            else { return event }
            jump(tabID: tabs.terminals[index].id, surfaceID: nil)
            return nil
        }
    }

    private func removeDigitKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// One agent tab row, with indented pane sub-rows for split tabs.
private struct AgentWatcherRowView: View {
    let row: AgentWatcherRow
    let now: Date
    /// Called with the pane to focus, or nil for the tab itself.
    let onJump: (UUID?) -> Void

    @State private var hovering = false

    private var needsYou: Bool { row.state == .needsYou }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { onJump(nil) } label: {
                HStack(spacing: 8) {
                    Text(row.position <= 9 ? "⌘\(row.position)" : "\(row.position)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiaryText)
                        .frame(width: 24, alignment: .leading)
                    Text(row.name)
                        .font(.system(size: 12, weight: needsYou ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    AgentStateChip(state: row.state, since: row.since, now: now)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(needsYou ? Color.orange : .secondary)
                        .opacity(hovering || needsYou ? 1 : 0)
                        .help("Go to tab \(row.position)")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(needsYou ? Color.orange.opacity(0.14) : .clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowHover()
            .onHover { hovering = $0 }
            .help("Go to tab \(row.position)")

            ForEach(row.panes) { pane in
                Button { onJump(pane.surfaceID) } label: {
                    HStack(spacing: 8) {
                        Text(pane.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        AgentStateChip(state: pane.state, since: pane.since, now: now)
                    }
                    .padding(.leading, 40).padding(.trailing, 8).padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowHover()
                .help("Go to this pane")
            }
        }
    }
}

/// A coloured state label with the time spent in that state.
private struct AgentStateChip: View {
    let state: AgentState
    let since: Date
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(state.watcherColor).frame(width: 6, height: 6)
            Text(AgentWatcherPresentation.label(for: state))
            Text(AgentWatcherPresentation.elapsed(now.timeIntervalSince(since)))
                .foregroundStyle(.tertiaryText)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(state.watcherColor)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(state.watcherColor.opacity(0.14)))
        .fixedSize()
    }
}

/// Opens Settings > AI Agents, where the watcher switch and agent hooks live.
private struct AIAgentsSettingsLink: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented = false
            SettingsController.shared.show(section: .aiAgents)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
                Text("AI Agents settings")
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowHover()
        .help("Set up agent hooks or turn the AI Agent Watcher off")
    }
}
