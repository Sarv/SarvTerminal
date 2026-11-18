import Foundation

/// AI coding agents a pane can be running, and how to resume each one by an
/// exact session id without ever landing on an interactive picker. Pure.
enum AgentKind: String, CaseIterable {
    case claude, codex, copilot, gemini, qwen, opencode, cursor, amp, crush, goose, droid, kimi, amazonQ, kiro, auggie, aider

    /// The command the user types to start it.
    var program: String {
        switch self {
        case .cursor: "cursor-agent"
        case .amazonQ: "q"
        case .kiro: "kiro-cli"
        default: rawValue
        }
    }

    /// Executable basenames that identify the agent's own process.
    private var executableNames: Set<String> {
        switch self {
        case .cursor: ["cursor-agent"]
        case .amazonQ: ["q"]
        case .kiro: ["kiro-cli"]
        default: [rawValue]
        }
    }

    /// Substrings of a script path that identify an npm-installed agent run
    /// through `node` (`node …/@openai/codex/bin/codex.js`).
    private var packageMarkers: [String] {
        switch self {
        case .claude: ["@anthropic-ai/claude-code"]
        case .codex: ["@openai/codex"]
        case .copilot: ["@github/copilot"]
        case .gemini: ["@google/gemini-cli"]
        case .qwen: ["@qwen-code/qwen-code"]
        case .opencode: ["opencode-ai"]
        case .amp: ["@sourcegraph/amp"]
        case .auggie: ["@augmentcode/auggie"]
        case .droid: ["@factory/cli"]
        default: []
        }
    }

    /// Which agent, if any, `argv` runs. Amazon Q and Kiro only count in their
    /// chat mode, since `q` is also a generic name.
    static func detect(_ argv: [String]) -> AgentKind? {
        guard let first = argv.first else { return nil }
        let name = PaneCommandLine.basename(first)
        let script = argv.count > 1 ? argv[1] : ""
        return allCases.first { kind in
            let named = kind.executableNames.contains(name)
                || kind.packageMarkers.contains { script.contains($0) }
            guard named else { return false }
            if kind == .amazonQ || kind == .kiro { return argv.contains("chat") }
            return true
        }
    }

    /// The agent's own arguments, after its program (or `node script`).
    static func agentArguments(_ argv: [String], kind: AgentKind) -> [String] {
        let interpreted = argv.count > 1 && !kind.executableNames.contains(PaneCommandLine.basename(argv[0]))
        return Array(argv.dropFirst(interpreted ? 2 : 1))
    }
}

/// What the agent's own files said about the session at save time.
enum AgentSessionEvidence: Equatable {
    /// The exact id of the conversation the process had open.
    case session(String)
    /// The process is verified but never saved a conversation (e.g. Claude
    /// opened and never sent a message): start it fresh.
    case none
    /// Nothing reliable found: never guess.
    case unknown
}

enum AgentResumeRules {
    /// Flags (value-taking, and boolean) safe to carry into the resumed run:
    /// they set how the agent behaves, never what it is asked to do.
    private static let keptFlags: [AgentKind: (valued: Set<String>, boolean: Set<String>)] = [
        .claude: (["--model", "--permission-mode", "--add-dir", "--agent", "--settings", "--mcp-config", "--fallback-model"],
                  ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--verbose", "--ide", "--chrome"]),
        .codex: (["-m", "--model", "-s", "--sandbox", "-a", "--ask-for-approval", "-p", "--profile"],
                 ["--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--search"]),
        .copilot: (["--model", "--add-dir"],
                   ["--allow-all-tools", "--allow-all-paths", "--allow-all", "--yolo"]),
    ]

    /// Flags whose value is an exact session id, per agent. A run launched
    /// with one of these is resumed with the same id even when the agent's
    /// files can't be read.
    private static let idFlags: [AgentKind: [String]] = [
        .claude: ["--resume", "-r", "--session-id"],
        .codex: [],
        .copilot: ["--resume"],
        .gemini: ["--resume", "-r", "--session-id"],
        .qwen: ["--resume", "-r", "--session-id"],
        .opencode: ["--session", "-s"],
        .cursor: ["--resume"],
        .crush: ["--session", "-s"],
        .goose: ["--session-id"],
        .droid: ["--resume", "-r"],
        .kimi: ["--session", "--resume", "-S", "-r"],
        .kiro: ["--resume-id"],
    ]

    /// The command for a reopened pane running `kind`: resumed by its exact
    /// session when one is known, otherwise the bare agent started fresh.
    static func restoreCommand(
        kind: AgentKind,
        argv: [String],
        evidence: AgentSessionEvidence
    ) -> SavedSession.RestoreCommand {
        let args = AgentKind.agentArguments(argv, kind: kind)
        let flags = kept(args, for: kind)
        let id: String? = if case .session(let found) = evidence { found } else { sessionID(in: args, kind: kind) }

        if let id, isSafeSessionID(id) {
            return command(resume(kind: kind, id: id) + flags)
        }
        // Amazon Q keeps one conversation per directory: `--resume` is exact.
        if kind == .amazonQ {
            return command(["q", "chat", "--resume"])
        }
        // No pinned session: start the agent fresh. Its prompt arguments are
        // never replayed, so nothing re-runs a task.
        return command([kind.program] + flags)
    }

    /// The resume invocation for an exact id.
    static func resume(kind: AgentKind, id: String) -> [String] {
        switch kind {
        case .codex: ["codex", "resume", id]
        case .amp: ["amp", "threads", "continue", id]
        case .goose: ["goose", "session", "--resume", "--session-id", id]
        case .kiro: ["kiro-cli", "chat", "--resume-id", id]
        case .opencode, .crush: [kind.program, "--session", id]
        case .kimi: ["kimi", "--session", id]
        default: [kind.program, "--resume", id]
        }
    }

    /// A session id found in the original argv, if it was launched pinned.
    static func sessionID(in args: [String], kind: AgentKind) -> String? {
        if kind == .codex, args.first == "resume", args.count > 1, !args[1].hasPrefix("-") {
            return args[1]
        }
        if kind == .amp, args.count > 2, args[0] == "threads", args[1] == "continue" {
            return args[2]
        }
        guard let flags = idFlags[kind] else { return nil }
        for (index, arg) in args.enumerated() {
            if let flag = flags.first(where: { arg.hasPrefix("\($0)=") }) {
                return String(arg.dropFirst(flag.count + 1))
            }
            if flags.contains(arg), index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                return args[index + 1]
            }
        }
        return nil
    }

    /// Ids are opaque tokens: letters, digits and `-_.:`, long enough that
    /// "latest" or a picker index ("3") can never pass as one.
    static func isSafeSessionID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        return id.count >= 8 && id.count <= 128
            && id.unicodeScalars.allSatisfy(allowed.contains)
            && id.lowercased() != "latest"
    }

    /// The behaviour flags from `args` worth keeping, in their original order.
    static func kept(_ args: [String], for kind: AgentKind) -> [String] {
        guard let rule = keptFlags[kind] else { return [] }
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            let name = arg.split(separator: "=", maxSplits: 1).first.map(String.init) ?? arg
            if rule.boolean.contains(arg) {
                result.append(arg)
            } else if rule.valued.contains(name), arg.contains("=") {
                result.append(arg)
            } else if rule.valued.contains(arg), index + 1 < args.count {
                result += [arg, args[index + 1]]
                index += 1
            }
            index += 1
        }
        return result
    }

    private static func command(_ words: [String]) -> SavedSession.RestoreCommand {
        .init(commandLine: words.map(Ghostty.Shell.quote).joined(separator: " "))
    }
}
