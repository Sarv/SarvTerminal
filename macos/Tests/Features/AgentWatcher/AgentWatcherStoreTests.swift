import Combine
import Foundation
import Testing
@testable import Ghostty

@MainActor
@Suite
struct AgentWatcherStoreTests {
    /// A clock the test moves by hand.
    final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private let clock = TestClock()
    private let pane = UUID()

    private func makeStore(doneHold: TimeInterval = 0) -> AgentWatcherStore {
        let clock = clock
        return AgentWatcherStore(clock: { clock.now }, doneHold: { doneHold })
    }

    private func sample(
        foreground: AgentForeground? = .agent(.claude), screenTail: String? = nil, onScreen: Bool = false
    ) -> AgentPaneSample {
        AgentPaneSample(foreground: foreground, screenTail: screenTail, onScreen: onScreen)
    }

    @Test func stalledWorkingBecomesDoneOnATick() {
        let store = makeStore()
        store.send(.progress(.active), to: pane)
        #expect(store.state(of: pane) == .working)

        clock.advance(AgentStateReducer.workingExpiry + 1)
        store.tick([pane: sample()])
        #expect(store.state(of: pane) == .done)
    }

    @Test func viewingADoneTabMakesItIdle() {
        let store = makeStore()
        store.send(.progress(.active), to: pane)
        store.send(.progress(.cleared), to: pane)
        #expect(store.state(of: pane) == .done)

        store.tick([pane: sample(onScreen: true)])
        #expect(store.state(of: pane) == .idle)
    }

    @Test func aViewedDoneTabStaysDoneForTheHold() {
        let store = makeStore(doneHold: 120)
        store.send(.progress(.active), to: pane)
        store.send(.progress(.cleared), to: pane)

        clock.advance(119)
        store.tick([pane: sample(onScreen: true)])
        #expect(store.state(of: pane) == .done)

        clock.advance(1)
        store.tick([pane: sample(onScreen: true)])
        #expect(store.state(of: pane) == .idle)
    }

    @Test func doneHoldFallsBackToTheDefault() {
        #expect(AgentDoneHold.stored(nil) == .twoMinutes)
        #expect(AgentDoneHold.stored(42) == .twoMinutes)
        #expect(AgentDoneHold.stored(300) == .fiveMinutes)
    }

    @Test func aPromptOnScreenNotifiesOnce() {
        let store = makeStore()
        var received: [AgentWatcherEffect] = []
        let subscription = store.effects.sink { received.append($0) }
        defer { subscription.cancel() }

        store.send(.progress(.active), to: pane)
        store.send(.progress(.cleared), to: pane)
        #expect(store.needsScreenSample(pane))

        let tail = "Do you want to create hello.txt?\n❯ 1. Yes\n  2. No\n"
        store.tick([pane: sample(screenTail: tail)])
        store.tick([pane: sample(screenTail: tail)])

        #expect(store.state(of: pane) == .needsYou)
        #expect(received == [AgentWatcherEffect(surfaceID: pane, effect: .notify)])
    }

    @Test func backgroundWorkKeepsTheScreenRead() {
        let store = makeStore()
        store.send(.progress(.active), to: pane)
        #expect(!store.needsScreenSample(pane))
        store.send(.progress(.cleared), to: pane)
        store.tick([pane: sample(screenTail: "────\n› \n────\n  1 shell · ← 1 agent")])
        #expect(store.state(of: pane) == .working)
        #expect(store.needsScreenSample(pane))
    }

    @Test func aNotifiedPromptIsNotReadFromTheScreen() {
        let store = makeStore()
        store.send(.progress(.active), to: pane)
        store.send(.notification("Claude needs your permission to use Bash"), to: pane)
        #expect(store.state(of: pane) == .needsYou)
        #expect(!store.needsScreenSample(pane))
    }

    @Test func closedPanesAreDropped() {
        let store = makeStore()
        store.send(.progress(.active), to: pane)
        #expect(store.snapshots[pane] != nil)
        store.tick([:])
        #expect(store.panes[pane] == nil)
        #expect(store.snapshots[pane] == nil)
    }

    @Test func aShellWithNoAgentStoresNothing() {
        let store = makeStore()
        store.tick([pane: sample(foreground: .shell)])
        #expect(store.panes.isEmpty)
        #expect(!store.needsScreenSample(pane))
    }
}
