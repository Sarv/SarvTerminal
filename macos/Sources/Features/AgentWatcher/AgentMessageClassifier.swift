import Foundation

/// Reads agent notification text and screen text. Pure; shared by the tab
/// banner path and the agent state reducer so both use one keyword list.
enum AgentMessageClassifier {
    enum Verdict: Equatable {
        case needsYou
        case idle
        case noChange
    }

    /// Words that say the user must act now. Specific enough to pin a lasting
    /// needs-you state.
    private static let clearAsk = [
        "permission", "approv", "confirm", "authoriz", "y/n", "yes/no",
        "needs your", "need your", "requires your", "require your",
        "action required", "action needed", "attention required",
        "needs attention", "input required", "response required",
        "allow", "deny", "grant",
    ]

    /// Looser hints that a message might want the user. Good enough for a
    /// one-off banner, too vague to hold a state.
    private static let looseAsk = [
        "requires", "decision", "decide", "choose", "select", "proceed",
        "review", "?",
    ]

    /// Turn-ended or idle messages: nothing is needed from the user.
    private static let idleWords = [
        "waiting for your", "waiting for input", "awaiting", "is ready",
        "ready for input", "standing by", "on standby", "task complete",
        "task finished", "is complete", "completed", "all done",
        "finished", "success", "succeeded", "idle", "no action needed",
        "nothing to do", "session ended", "session complete",
        "up to date", "turn complete", "response complete",
        "generation complete",
    ]

    /// A live selection menu: the cursor (Claude's `❯`, Codex's `›`) on a
    /// numbered option, as in `❯ 1. Yes`. Agents draw it only while they wait
    /// for a choice and replace it once answered, so transcript text such as
    /// "Allowed by auto mode" or a question in prose never matches.
    private static let menuCursor = /^\s*[❯›]\s*\d+\.\s/

    /// How many non-blank lines from the bottom count as "the prompt area".
    private static let promptLineWindow = 15

    /// Banner verdict: whether a notification message warrants a banner rather
    /// than just flagging the tab. Agents send a message both when they need the
    /// user ("… needs your permission") and when they merely end their turn
    /// ("… is waiting for your input"). Actionable text always wins; otherwise
    /// only clearly idle text is suppressed, so a new or unknown message is
    /// never silently dropped.
    static func needsAttention(_ body: String) -> Bool {
        let text = body.lowercased()
        // Checked first so "waiting for your approval" still banners.
        if (clearAsk + looseAsk).contains(where: text.contains) { return true }
        return !idleWords.contains(where: text.contains)
    }

    /// Whether the tab banner path should banner this message. When the pane
    /// runs an agent and the message moves it to needs you, the watcher sends
    /// that banner instead, so it is not sent twice.
    static func bannersTabMessage(_ body: String, paneIsAgent: Bool) -> Bool {
        if paneIsAgent && verdict(body) == .needsYou { return false }
        return needsAttention(body)
    }

    /// State verdict. Only a clear ask moves a pane to needs you; unknown or
    /// vague text changes nothing.
    static func verdict(_ body: String) -> Verdict {
        let text = body.lowercased()
        if clearAsk.contains(where: text.contains) { return .needsYou }
        if idleWords.contains(where: text.contains) { return .idle }
        return .noChange
    }

    /// The bullet an agent puts before each message: Claude's `⏺` (some
    /// fonts draw `●`) and Codex's `•`.
    private static let messageBullets: Set<Character> = ["⏺", "●", "•"]

    /// A message that waits for a typed answer: it ends with a question mark
    /// or asks for yes/no or y/n, allowing a closing bracket or full stop.
    private static let questionEnding = /(\?|\b(yes or no|yes\/no|y\/n))[\s.)\]]*$/.ignoresCase()

    /// A live count of background work in an agent's footer: Claude Code's
    /// `4 shells, 1 monitor` or `1 background task`. Not `← 1 agent`: that
    /// hint stays after the subagent has finished.
    private static let backgroundCount = /\b\d+\s+(shells?|monitors?|background\s+tasks?|bash(es)?)\b/
        .ignoresCase()

    /// Claude Code's status line while its turn waits on subagents:
    /// `✻ Waiting for 1 background agent to finish`.
    private static let waitingForBackground = /waiting\s+for\s+\d+\s+background\s+(agents?|tasks?)/
        .ignoresCase()

    /// A line of the input box's frame: box-drawing characters only.
    private static func isBoxRule(_ line: Substring) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        return !chars.isEmpty && chars.allSatisfy { "─━═╭╮╰╯┌┐└┘".contains($0) }
    }

    /// Whether work still runs in the background after the agent's turn
    /// ended: the footer (lines under the input box) counts running shells
    /// or monitors, or the status line just above the box says the agent is
    /// waiting on background agents. Older transcript lines and the typed
    /// input never count.
    static func showsBackgroundWork(_ screenTail: String) -> Bool {
        let lines = screenTail.split(separator: "\n", omittingEmptySubsequences: false)
        guard let bottom = lines.lastIndex(where: isBoxRule) else { return false }
        if lines[(bottom + 1)...].contains(where: { $0.contains(backgroundCount) }) { return true }
        let above = lines[..<bottom]
        let top = above.lastIndex(where: isBoxRule) ?? bottom
        let statusLine = lines[..<top].last { !$0.allSatisfy(\.isWhitespace) }
        return statusLine?.contains(waitingForBackground) == true
    }

    /// Whether the agent is waiting on the user in `screenTail`: a selection
    /// menu in the last lines, or a last message that asks a question.
    static func showsPrompt(_ screenTail: String) -> Bool {
        let lines = screenTail.split(separator: "\n", omittingEmptySubsequences: false)
        let menuShown = lines
            .filter { !$0.allSatisfy(\.isWhitespace) }
            .suffix(promptLineWindow)
            .contains { line in line.contains(menuCursor) }
        return menuShown || lastMessageEnding(lines).map { $0.contains(questionEnding) } == true
    }

    /// The last line of the agent's last message: the final bulleted line
    /// and its indented continuation, up to the next unindented line (the
    /// status line or input box). Nil when no message is on screen.
    private static func lastMessageEnding(_ lines: [Substring]) -> Substring? {
        let isMessageStart = { (line: Substring) in
            line.first { !$0.isWhitespace }.map(messageBullets.contains) == true
        }
        guard let start = lines.lastIndex(where: isMessageStart) else { return nil }
        let continuation = lines[(start + 1)...].prefix { line in
            line.allSatisfy(\.isWhitespace) || line.first?.isWhitespace == true
        }
        let ending = ([lines[start]] + continuation).last { !$0.allSatisfy(\.isWhitespace) }
        return ending?.drop { $0.isWhitespace || messageBullets.contains($0) }
    }
}
