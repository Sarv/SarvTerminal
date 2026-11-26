import Foundation
import Testing
@testable import Ghostty

@Suite
struct AgentMessageClassifierTests {
    @Test func bannerVerdictKeepsActionableMessages() {
        #expect(AgentMessageClassifier.needsAttention("Claude needs your permission to use Bash"))
        #expect(AgentMessageClassifier.needsAttention("Waiting for your approval"))
        #expect(AgentMessageClassifier.needsAttention("Please review the diff?"))
        #expect(AgentMessageClassifier.needsAttention("Something new happened"))
    }

    @Test func bannerVerdictDropsIdleMessages() {
        #expect(!AgentMessageClassifier.needsAttention("Claude is waiting for your input"))
        #expect(!AgentMessageClassifier.needsAttention("Task complete"))
        #expect(!AgentMessageClassifier.needsAttention("All done"))
    }

    @Test func stateVerdictNeedsYouOnlyForAClearAsk() {
        #expect(AgentMessageClassifier.verdict("Claude needs your permission to use Write") == .needsYou)
        #expect(AgentMessageClassifier.verdict("Approve this command? (y/n)") == .needsYou)
        #expect(AgentMessageClassifier.verdict("Waiting for your approval") == .needsYou)
    }

    @Test func stateVerdictIgnoresVagueText() {
        #expect(AgentMessageClassifier.verdict("Please review the diff?") == .noChange)
        #expect(AgentMessageClassifier.verdict("Select a file") == .noChange)
        #expect(AgentMessageClassifier.verdict("?") == .noChange)
        #expect(AgentMessageClassifier.verdict("Something new happened") == .noChange)
    }

    @Test func stateVerdictTreatsWaitingForInputAsIdle() {
        #expect(AgentMessageClassifier.verdict("Claude is waiting for your input") == .idle)
        #expect(AgentMessageClassifier.verdict("Task complete") == .idle)
    }

    @Test func promptPhraseIsFoundInTheLastLinesOnly() {
        #expect(AgentMessageClassifier.showsPrompt("x\nDo you want to create hello.txt?\n❯ 1. Yes\n"))
        let oldPrompt = "Do you want to create a.txt?\n❯ 1. Yes\n" + String(repeating: "line\n", count: 20)
        #expect(!AgentMessageClassifier.showsPrompt(oldPrompt))
        #expect(!AgentMessageClassifier.showsPrompt("> \n  ? for shortcuts"))
    }

    @Test func backgroundWorkIsReadFromTheFooterOnly() {
        let transcript = "⏺ Committed.\n✻ Baked for 25s · done 2:29 PM · 4 shells, 1 monitor still running\n"
        let box = "────────────\n› push it\n────────────\n"
        #expect(AgentMessageClassifier.showsBackgroundWork(
            transcript + box + "▸▸ auto mode on · 4 shells, 1 monitor · ← 1 agent · ↓ to manage"))
        #expect(AgentMessageClassifier.showsBackgroundWork(box + "  1 background task · ? for shortcuts"))
        // The agent hint stays after the subagent finished: not running work.
        #expect(!AgentMessageClassifier.showsBackgroundWork(
            "✻ Churned for 1m 7s · done 2:38 PM\n" + box + "▸▸ auto mode on (shift+tab to cycle) · ← 1 agent"))
        // While the turn waits on a subagent, the status line above the box says so.
        #expect(AgentMessageClassifier.showsBackgroundWork(
            "✻ Waiting for 1 background agent to finish\n\n" + box + "▸▸ auto mode on · ← 1 agent"))
        // An old waiting line further up the transcript doesn't count.
        #expect(!AgentMessageClassifier.showsBackgroundWork(
            "✻ Waiting for 1 background agent to finish\n⏺ It finished.\n" + box + "  ← 1 agent"))
        // The same words above the box or typed into it don't count.
        #expect(!AgentMessageClassifier.showsBackgroundWork(transcript + box + "▸▸ auto mode on · ? for shortcuts"))
        #expect(!AgentMessageClassifier.showsBackgroundWork("────\n› start 2 shells\n────\n  ? for shortcuts"))
        #expect(!AgentMessageClassifier.showsBackgroundWork("no box here · 2 shells"))
    }

    @Test func aCodexMenuIsAPrompt() {
        #expect(AgentMessageClassifier.showsPrompt("Allow command?\n› 1. Yes\n  2. No\n"))
    }

    @Test func aFinishedTurnIsNotAPrompt() {
        let tail = """
        ⏺ Bash(sleep 30)
          ⎿  Allowed by auto mode
        ⏺ Do you want to run another round? Would you like to stop?
        ⏺ I've stopped the session.
        ✻ Cogitated for 4s · done 2:16 PM
        ╭──────────────────────────╮
        │ ❯                        │
        ╰──────────────────────────╯
          ? for shortcuts
        """
        #expect(!AgentMessageClassifier.showsPrompt(tail))
    }

    @Test func aTypedQuestionIsAPrompt() {
        let box = "\n✻ Cogitated for 4s\n╭────╮\n│ ❯  │\n╰────╯\n"
        #expect(AgentMessageClassifier.showsPrompt("⏺ Round 1 is done. Run another\n  30 seconds?" + box))
        #expect(AgentMessageClassifier.showsPrompt("⏺ Run another round? (yes/no)" + box))
        #expect(AgentMessageClassifier.showsPrompt("⏺ Shall I continue? Type yes or no." + box))
        #expect(AgentMessageClassifier.showsPrompt("• Apply the patch [y/N]" + box))
    }

    @Test func aStatementAboutYesOrNoIsNotAPrompt() {
        let box = "\n✻ Cogitated for 4s\n│ ❯  │\n"
        #expect(!AgentMessageClassifier.showsPrompt("⏺ I'll ask you yes or no when it ends." + box))
        #expect(!AgentMessageClassifier.showsPrompt("⏺ Is it done? Yes.\n⏺ Round 2 started." + box))
    }

    @Test func blankLinesDoNotPushThePromptOutOfRange() {
        let tail = "Do you want to proceed?\n❯ 1. Yes\n" + String(repeating: "\n   \n", count: 30)
        #expect(AgentMessageClassifier.showsPrompt(tail))
    }

    @Test func theWatcherOwnsAnAgentPanesNeedsYouBanner() {
        let ask = "Claude needs your permission to use Bash"
        #expect(!AgentMessageClassifier.bannersTabMessage(ask, paneIsAgent: true))
        #expect(AgentMessageClassifier.bannersTabMessage(ask, paneIsAgent: false))
        // A loose ask does not move the state, so the tab path still banners it.
        #expect(AgentMessageClassifier.bannersTabMessage("Which option should I choose?", paneIsAgent: true))
        #expect(!AgentMessageClassifier.bannersTabMessage("Claude is waiting for your input", paneIsAgent: true))
    }
}
