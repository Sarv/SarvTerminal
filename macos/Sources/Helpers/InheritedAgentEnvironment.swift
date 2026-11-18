import Foundation

/// Claude Code's per-session variables that leak into the app when it is
/// launched from inside a Claude session (`open` passes the caller's
/// environment on, e.g. `scripts/dev.sh` run by an agent). Every shell the app
/// spawns would inherit them, so a `claude` started there runs as a child
/// session: it writes no `~/.claude/sessions/<pid>.json`, and "Reopen All"
/// can't resume it — it comes back as a bare `claude` left at the prompt.
enum InheritedAgentEnvironment {
    private static let exactNames: Set<String> = ["CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT"]
    private static let prefix = "CLAUDE_CODE_"

    /// The names in `environment` that belong to a parent Claude session.
    static func leakedNames(in environment: [String: String]) -> [String] {
        environment.keys.filter { exactNames.contains($0) || $0.hasPrefix(prefix) }.sorted()
    }

    /// Remove them from this process before any shell is spawned.
    static func scrub() {
        for name in leakedNames(in: ProcessInfo.processInfo.environment) {
            unsetenv(name)
        }
    }
}
