import Foundation
import Testing
@testable import Ghostty

@Suite
struct AgentWatcherPresentationTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func tab(_ name: String, panes: Int = 1) -> AgentWatcherTabInput {
        AgentWatcherTabInput(
            tabID: UUID(), name: name,
            panes: (0..<panes).map { AgentWatcherTabInput.Pane(surfaceID: UUID(), name: "\(name)-\($0)") })
    }

    private func snapshot(_ state: AgentState) -> AgentPaneSnapshot {
        AgentPaneSnapshot(state: state, since: start)
    }

    // Rows.

    @Test func rowsFollowTabPositionAndSkipTabsWithoutAgents() {
        let tabs = [tab("a"), tab("b"), tab("c"), tab("d")]
        let panes = [
            tabs[3].panes[0].surfaceID: snapshot(.needsYou),
            tabs[0].panes[0].surfaceID: snapshot(.working),
            tabs[2].panes[0].surfaceID: snapshot(.idle),
        ]
        let list = AgentWatcherPresentation.rows(tabs: tabs, panes: panes)
        #expect(list.rows.map(\.position) == [1, 3, 4])
        #expect(list.rows.map(\.name) == ["a", "c", "d"])
        #expect(list.rows.map(\.state) == [.working, .idle, .needsYou])
        #expect(list.tabsWithoutAgent == 1)
    }

    @Test func aTabWithTwoAgentPanesListsBothAndShowsTheMostUrgent() {
        let split = tab("split", panes: 3)
        let panes = [
            split.panes[0].surfaceID: snapshot(.working),
            split.panes[2].surfaceID: snapshot(.needsYou),
        ]
        let row = AgentWatcherPresentation.rows(tabs: [split], panes: panes).rows[0]
        #expect(row.state == .needsYou)
        #expect(row.panes.map(\.name) == ["split-0", "split-2"])
    }

    @Test func aTabWithOneAgentPaneHasNoSubRows() {
        let split = tab("split", panes: 2)
        let row = AgentWatcherPresentation.rows(
            tabs: [split], panes: [split.panes[1].surfaceID: snapshot(.done)]).rows[0]
        #expect(row.panes.isEmpty)
    }

    @Test func noAgentTabsGivesAnEmptyListWithTheOtherTabCount() {
        let list = AgentWatcherPresentation.rows(tabs: [tab("a"), tab("b")], panes: [:])
        #expect(list.rows.isEmpty)
        #expect(list.tabsWithoutAgent == 2)
    }

    // Icon summary.

    @Test func twoTabsNeedingYouBadgeAndPulse() {
        let summary = AgentWatcherPresentation.summary(tabStates: [.needsYou, .needsYou, .idle], reduceMotion: false)
        #expect(summary == AgentWatcherSummary(needsYouCount: 2, pulses: true, alertTint: false, workingTint: false))
    }

    @Test func onlyWorkingTintsWithoutABadge() {
        let summary = AgentWatcherPresentation.summary(tabStates: [.working, .idle], reduceMotion: false)
        #expect(summary == AgentWatcherSummary(
            needsYouCount: 0, pulses: false, alertTint: false, workingTint: true, breathes: true))
    }

    @Test func reduceMotionKeepsTheWorkingTintWithoutBreathing() {
        let summary = AgentWatcherPresentation.summary(tabStates: [.working], reduceMotion: true)
        #expect(summary == AgentWatcherSummary(needsYouCount: 0, pulses: false, alertTint: false, workingTint: true))
    }

    @Test func allIdleIsPlain() {
        let summary = AgentWatcherPresentation.summary(tabStates: [.idle, .noAgent], reduceMotion: false)
        #expect(summary == AgentWatcherSummary(needsYouCount: 0, pulses: false, alertTint: false, workingTint: false))
    }

    @Test func needsYouWinsOverWorking() {
        let summary = AgentWatcherPresentation.summary(tabStates: [.needsYou, .working], reduceMotion: false)
        #expect(summary == AgentWatcherSummary(needsYouCount: 1, pulses: true, alertTint: false, workingTint: false))
    }

    @Test func reduceMotionSwapsThePulseForAStaticTint() {
        let summary = AgentWatcherPresentation.summary(tabStates: [.needsYou], reduceMotion: true)
        #expect(summary == AgentWatcherSummary(needsYouCount: 1, pulses: false, alertTint: true, workingTint: false))
    }

    // Digit keys.

    @Test func digitsJumpToTabPositionsThatExist() {
        #expect(AgentWatcherPresentation.tabIndex(forDigit: 4, tabCount: 4) == 3)
        #expect(AgentWatcherPresentation.tabIndex(forDigit: 1, tabCount: 4) == 0)
        #expect(AgentWatcherPresentation.tabIndex(forDigit: 5, tabCount: 4) == nil)
        #expect(AgentWatcherPresentation.tabIndex(forDigit: 0, tabCount: 4) == nil)
    }

    // Chip dots.

    @Test func chipDotsFollowAgentState() {
        #expect(AgentWatcherPresentation.chipDot(agentState: .needsYou, hasAttention: false)
                == AgentChipDot(color: .orange, label: "Agent needs you"))
        #expect(AgentWatcherPresentation.chipDot(agentState: .working, hasAttention: false)
                == AgentChipDot(color: .blue, label: "Agent working"))
        #expect(AgentWatcherPresentation.chipDot(agentState: .done, hasAttention: false)
                == AgentChipDot(color: .green, label: "Agent done"))
        #expect(AgentWatcherPresentation.chipDot(agentState: .idle, hasAttention: true) == nil)
    }

    @Test func tabsWithoutAnAgentKeepTheAttentionDot() {
        #expect(AgentWatcherPresentation.chipDot(agentState: .noAgent, hasAttention: true)?.color == .orange)
        #expect(AgentWatcherPresentation.chipDot(agentState: .noAgent, hasAttention: false) == nil)
    }

    // Time in state.

    @Test func elapsedIsShortAndMinuteGrained() {
        #expect(AgentWatcherPresentation.elapsed(20) == "now")
        #expect(AgentWatcherPresentation.elapsed(12 * 60 + 5) == "12m")
        #expect(AgentWatcherPresentation.elapsed(2 * 3600) == "2h")
        #expect(AgentWatcherPresentation.elapsed(2 * 3600 + 5 * 60) == "2h 5m")
    }
}
