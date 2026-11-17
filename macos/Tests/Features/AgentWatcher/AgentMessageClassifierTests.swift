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
