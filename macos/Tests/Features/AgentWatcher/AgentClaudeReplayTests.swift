import Combine
import Foundation
import Testing
@testable import Ghostty

/// Replays the signals a real Claude Code session sent (a file write that
/// asked for permission, was approved, finished, then exited) through the
/// store, with watcher ticks every 2 seconds in between.
@MainActor
@Suite
struct AgentClaudeReplayTests {
    final class TestClock {
        var now = Date(timeIntervalSince1970: 0)
    }

    /// Seconds from launch and the signal Claude sent then. The empty title on
    /// exit is replaced by the pwd, as the core does.
    private let recording: [(TimeInterval, AgentEvent)] = [
        (0.27, .title("✳ Claude Code")),
        (0.27, .progress(.cleared)),
        (35.69, .title("◐ Claude Code")),
        (35.70, .progress(.active)),
        (36.66, .title("◑ Claude Code")),
        (37.06, .title("◑ Hello2.txt file creation")),
        (37.62, .title("◐ Hello2.txt file creation")),
        (38.58, .title("◑ Hello2.txt file creation")),
        (39.54, .title("◐ Hello2.txt file creation")),
        (39.74, .title("✳ Hello2.txt file creation")),
        (39.74, .progress(.cleared)),
        (45.75, .notification("Claude needs your permission")),
        (115.92, .title("◐ Hello2.txt file creation")),
        (115.93, .progress(.active)),
        (116.89, .title("◑ Hello2.txt file creation")),
        (117.85, .title("✳ Hello2.txt file creation")),
        (117.85, .progress(.cleared)),
        (177.87, .notification("Claude is waiting for your input")),
        (226.62, .progress(.cleared)),
        (226.62, .title("~/claude_capture_ws")),
    ]
    /// Claude has exited by the first tick after this.
    private let exitedAt: TimeInterval = 226.62
    private let end: TimeInterval = 240

    @Test func aRecordedClaudeSessionMovesThroughEveryState() {
        let clock = TestClock()
        let store = AgentWatcherStore(clock: { clock.now })
        let pane = UUID()
        var effects: [AgentEffect] = []
        let subscription = store.effects.sink { effects.append($0.effect) }
        defer { subscription.cancel() }

        var states: [AgentState] = []
        func record() {
            let state = store.state(of: pane)
            if states.last != state { states.append(state) }
        }

        var pending = recording[...]
        var tickAt: TimeInterval = 2
        while tickAt <= end {
            while let (time, event) = pending.first, time < tickAt {
                clock.now = Date(timeIntervalSince1970: time)
                store.send(event, to: pane)
                record()
                pending = pending.dropFirst()
            }
            clock.now = Date(timeIntervalSince1970: tickAt)
            let foreground = tickAt > exitedAt ? "zsh" : "claude"
            store.tick([pane: AgentPaneSample(foreground: foreground, screenTail: nil, onScreen: false)])
            record()
            tickAt += AgentWatcherStore.tickInterval
        }

        #expect(states == [.idle, .working, .done, .needsYou, .working, .done, .noAgent])
        #expect(effects == [.notify])
    }
}
