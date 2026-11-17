import Foundation
import Testing
@testable import Ghostty

@Suite
struct AgentStateReducerTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    /// Feeds events in order, each at its own second offset, and returns the
    /// final pane plus every effect that fired along the way.
    private func run(
        _ events: [(TimeInterval, AgentEvent)],
        from pane: AgentPaneState? = nil
    ) -> (AgentPaneState, [AgentEffect]) {
        var current = pane ?? AgentPaneState(since: start)
        var effects: [AgentEffect] = []
        for (offset, event) in events {
            let result = AgentStateReducer.reduce(current, event, now: at(offset))
            current = result.pane
            effects += result.effects
        }
        return (current, effects)
    }

    private let permissionTail = """
    Create file
    hello.txt
    Do you want to create hello.txt?
    ❯ 1. Yes
      2. Yes, allow all edits during this session
      3. No
    """

    // MARK: working and done

    @Test func progressStartsWorkingAndClearingMakesItDone() {
        let (working, _) = run([(0, .progress(.active))])
        #expect(working.state == .working)

        let (done, effects) = run([(0, .progress(.active)), (5, .progress(.cleared))])
        #expect(done.state == .done)
        #expect(done.since == at(5))
        #expect(effects.isEmpty)
    }

    @Test func spinnerTitleFromNoAgentStartsWorking() {
        let (pane, _) = run([(0, .title("◐ Fixing tests"))])
        #expect(pane.state == .working)
    }

    @Test func sparkleTitleMarksAnIdleAgent() {
        let (pane, _) = run([(0, .title("✳ Claude Code"))])
        #expect(pane.state == .idle)
    }

    @Test func plainTitleOnAPlainShellStaysNoAgent() {
        let (pane, _) = run([(0, .title("~/projects"))])
        #expect(pane.state == .noAgent)
    }

    @Test func workingWithoutRefreshFor20SecondsBecomesDone() {
        let (expired, _) = run([(0, .progress(.active)), (20, .tick)])
        #expect(expired.state == .done)

        let (refreshed, _) = run([(0, .progress(.active)), (19, .progress(.active)), (20, .tick)])
        #expect(refreshed.state == .working)

        let (spinning, _) = run([(0, .progress(.active)), (19, .title("◑ Fixing tests")), (20, .tick)])
        #expect(spinning.state == .working)
    }

    // MARK: viewing

    @Test func viewingWorkingKeepsWorkingAndViewingDoneMakesIdle() {
        let (working, _) = run([(0, .progress(.active)), (1, .viewed(doneHold: 0))])
        #expect(working.state == .working)

        let (idle, _) = run([(0, .progress(.active)), (5, .progress(.cleared)), (6, .viewed(doneHold: 0))])
        #expect(idle.state == .idle)
    }

    @Test func viewingDoneKeepsDoneUntilTheHoldPasses() {
        let finished: [(TimeInterval, AgentEvent)] = [(0, .progress(.active)), (5, .progress(.cleared))]
        let (held, _) = run(finished + [(64, .viewed(doneHold: 60))])
        #expect(held.state == .done)

        let (idle, _) = run(finished + [(64, .viewed(doneHold: 60)), (65, .viewed(doneHold: 60))])
        #expect(idle.state == .idle)
    }

    @Test func viewingNeedsYouKeepsNeedsYou() {
        let (pane, _) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (7, .screenSample(permissionTail)), (8, .viewed(doneHold: 0)),
        ])
        #expect(pane.state == .needsYou)
    }

    // MARK: needs you

    @Test func promptOnScreenAfterDonePromotesToNeedsYouOnce() {
        let (pane, effects) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (7, .screenSample(permissionTail)),
            (9, .screenSample(permissionTail)),
        ])
        #expect(pane.state == .needsYou)
        #expect(pane.needsYouSource == .screen)
        #expect(effects == [.notify])
    }

    @Test func laterPermissionNotificationDoesNotNotifyAgain() {
        let (pane, effects) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (7, .screenSample(permissionTail)),
            (11, .notification("Claude needs your permission to use Write")),
        ])
        #expect(pane.state == .needsYou)
        #expect(effects == [.notify])
    }

    @Test func permissionNotificationWhileWorkingNeedsYou() {
        let (pane, effects) = run([
            (0, .progress(.active)),
            (3, .notification("Claude needs your permission to use Bash")),
        ])
        #expect(pane.state == .needsYou)
        #expect(pane.needsYouSource == .notification)
        #expect(effects == [.notify])
    }

    @Test func promptLeavingTheScreenWithoutProgressMakesIdle() {
        let (pane, _) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (7, .screenSample(permissionTail)),
            (12, .screenSample("> \n  ? for shortcuts")),
        ])
        #expect(pane.state == .idle)
    }

    @Test func notificationAndStatusNeedsYouSurviveAPromptFreeScreen() {
        let (fromNotification, _) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (6, .notification("Claude needs your permission to use Write")),
            (8, .screenSample("> ")),
        ])
        #expect(fromNotification.state == .needsYou)

        let (fromStatus, _) = run([
            (0, .programStatus(.working)),
            (2, .programStatus(.blocked)),
            (4, .screenSample("> ")),
        ])
        #expect(fromStatus.state == .needsYou)
        #expect(fromStatus.needsYouSource == .programStatus)
    }

    @Test func resumingWorkClearsNeedsYou() {
        let (pane, _) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (7, .screenSample(permissionTail)), (20, .progress(.active)),
        ])
        #expect(pane.state == .working)
        #expect(pane.needsYouSource == nil)
    }

    @Test func promptOnANoAgentPaneIsIgnored() {
        let (pane, effects) = run([(0, .screenSample(permissionTail))])
        #expect(pane.state == .noAgent)
        #expect(effects.isEmpty)
    }

    @Test func reviewQuestionDoesNotPinNeedsYou() {
        let (pane, effects) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (6, .notification("Please review the diff?")),
        ])
        #expect(pane.state == .done)
        #expect(effects.isEmpty)
    }

    @Test func waitingForInputLeavesDoneAndIdleAlone() {
        let waiting = AgentEvent.notification("Claude is waiting for your input")
        let (done, _) = run([(0, .progress(.active)), (5, .progress(.cleared)), (65, waiting)])
        #expect(done.state == .done)

        let (idle, _) = run([(0, .title("✳ Claude Code")), (60, waiting)])
        #expect(idle.state == .idle)
    }

    // MARK: reminders

    @Test func needsYouRemindsEveryFiveMinutes() {
        let base: [(TimeInterval, AgentEvent)] = [
            (0, .progress(.active)), (5, .progress(.cleared)), (10, .screenSample(permissionTail)),
        ]
        let (_, early) = run(base + [(309, .tick)])
        #expect(early == [.notify])

        let (_, first) = run(base + [(310, .tick)])
        #expect(first == [.notify, .remind])

        let (_, second) = run(base + [(310, .tick), (400, .tick), (610, .tick)])
        #expect(second == [.notify, .remind, .remind])
    }

    @Test func aLongSleepFiresOneReminderNotABurst() {
        let (_, effects) = run([
            (0, .progress(.active)), (5, .progress(.cleared)),
            (10, .screenSample(permissionTail)), (4000, .tick), (4002, .tick),
        ])
        #expect(effects == [.notify, .remind])
    }

    // MARK: program status (OSC 7501)

    @Test func programStatusSetsStateDirectly() {
        let (blocked, effects) = run([(0, .programStatus(.blocked))])
        #expect(blocked.state == .needsYou)
        #expect(effects == [.notify])

        #expect(run([(0, .programStatus(.error))]).0.state == .done)
        #expect(run([(0, .programStatus(.done))]).0.state == .done)
        #expect(run([(0, .programStatus(.working))]).0.state == .working)
        #expect(run([(0, .programStatus(.working)), (1, .programStatus(.idle))]).0.state == .idle)
    }

    // MARK: exit

    @Test func plainTitleAfterClearedProgressMeansTheAgentExited() {
        // Claude's exit sends an empty title; the core swaps it for the pwd.
        let (exited, _) = run([
            (0, .title("✳ Claude Code")), (1, .progress(.active)),
            (5, .progress(.cleared)), (6, .title("/Users/me/project")),
        ])
        #expect(exited.state == .noAgent)

        let (stillThere, _) = run([
            (0, .progress(.active)), (5, .progress(.cleared)), (6, .title("✳ Claude Code")),
        ])
        #expect(stillThere.state == .done)
    }

    @Test func shellInTheForegroundEndsTheAgent() {
        let (exited, _) = run([(0, .foreground("claude")), (5, .title("~/p")), (9, .foreground("zsh"))])
        #expect(exited.state == .noAgent)

        // While the agent's title still carries its glyph, a shell child is the
        // agent running a command, not the agent leaving.
        let (running, _) = run([(0, .title("✳ Claude Code")), (5, .foreground("bash"))])
        #expect(running.state == .idle)
    }

    @Test func agentProcessInTheForegroundMarksAnIdleAgent() {
        #expect(run([(0, .foreground("claude"))]).0.state == .idle)
        #expect(run([(0, .foreground("ssh"))]).0.state == .noAgent)
    }

    // MARK: tab aggregation

    @Test func tabTakesItsMostUrgentPane() {
        #expect(AgentStateReducer.tabState([.idle, .needsYou, .working]) == .needsYou)
        #expect(AgentStateReducer.tabState([.idle, .done, .working]) == .done)
        #expect(AgentStateReducer.tabState([.idle, .working]) == .working)
        #expect(AgentStateReducer.tabState([.noAgent, .idle]) == .idle)
        #expect(AgentStateReducer.tabState([.noAgent]) == .noAgent)
        #expect(AgentStateReducer.tabState([]) == .noAgent)
    }
}
