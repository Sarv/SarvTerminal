import Foundation
import Testing
@testable import Ghostty

/// One tab running several agents in split panes.
@Suite
struct AgentWatcherSplitPaneTests {
    private let left = UUID()
    private let right = UUID()
    private let shell = UUID()
    private let since = Date(timeIntervalSince1970: 1_000)

    private func snapshots(_ states: [UUID: AgentState]) -> [UUID: AgentPaneSnapshot] {
        states.mapValues { AgentPaneSnapshot(state: $0, since: since) }
    }

    @Test func aTabTakesItsMostUrgentPane() {
        let panes = snapshots([left: .working, right: .needsYou])
        #expect(AgentWatcherPresentation.tabState(surfaceIDs: [left, right, shell], snapshots: panes) == .needsYou)
        #expect(AgentWatcherPresentation.tabState(surfaceIDs: [shell], snapshots: panes) == .noAgent)
    }

    @Test func aJumpLandsOnTheAgentThatNeedsYou() {
        let panes = snapshots([left: .working, right: .needsYou])
        #expect(AgentWatcherPresentation.leadPane(of: [shell, left, right], snapshots: panes) == right)
    }

    @Test func aTieGoesToTheLeftmostPane() {
        let panes = snapshots([left: .done, right: .done])
        #expect(AgentWatcherPresentation.leadPane(of: [left, right], snapshots: panes) == left)
    }

    @Test func aTabWithoutAnAgentHasNoLeadPane() {
        #expect(AgentWatcherPresentation.leadPane(of: [shell], snapshots: [:]) == nil)
        let idleOnly = snapshots([shell: .noAgent])
        #expect(AgentWatcherPresentation.leadPane(of: [shell], snapshots: idleOnly) == nil)
    }

    @Test func everyPaneShowsInTheGrid() {
        let visible = AgentWatcherPresentation.visiblePanes(
            all: [left, right], zoomed: nil, focusMode: false, focusModeSurfaceID: nil)
        #expect(visible == [left, right])
    }

    @Test func aZoomedSplitHidesTheOtherPanes() {
        let visible = AgentWatcherPresentation.visiblePanes(
            all: [left, right], zoomed: [right], focusMode: false, focusModeSurfaceID: nil)
        #expect(visible == [right])
    }

    @Test func focusModeShowsOnlyTheChosenPane() {
        let chosen = AgentWatcherPresentation.visiblePanes(
            all: [left, right], zoomed: nil, focusMode: true, focusModeSurfaceID: right)
        #expect(chosen == [right])
        let stale = AgentWatcherPresentation.visiblePanes(
            all: [left, right], zoomed: nil, focusMode: true, focusModeSurfaceID: shell)
        #expect(stale == [left])
    }

    @Test func aSplitTabsBannerNamesThePane() {
        #expect(AgentWatcherPresentation.bannerName(tab: "api", pane: "claude", paneCount: 2) == "api › claude")
        #expect(AgentWatcherPresentation.bannerName(tab: "api", pane: "claude", paneCount: 1) == "api")
        #expect(AgentWatcherPresentation.bannerName(tab: "api", pane: "", paneCount: 2) == "api")
    }
}
