import Foundation

/// Where an agent's files are, given the home folder, the environment and
/// what exists on disk. Injected so the path rules are unit testable.
struct AgentHookPaths {
    let home: URL
    let environment: [String: String]
    let fileExists: (URL) -> Bool

    static var live: AgentHookPaths {
        AgentHookPaths(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    /// `$<variable>` when set and non-empty, else `~/<fallback>`.
    func directory(_ variable: String?, fallback: String) -> URL {
        if let variable, let value = environment[variable], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return home.appendingPathComponent(fallback)
    }
}

/// The file an agent's hooks go into and how that file holds them.
struct AgentHookTarget {
    let url: URL
    let format: any AgentHookFormat
}

/// One AI agent whose hooks SarvTerminal can install so the agent reports
/// its exact state to the watcher.
struct AgentHookIntegration: Identifiable {
    let id: String
    let name: String
    /// Foreground process names that mean this agent runs in a pane.
    let processNames: Set<String>
    /// A file or folder whose presence means the agent is on this Mac.
    let detection: (AgentHookPaths) -> URL
    let target: (AgentHookPaths) -> AgentHookTarget
    /// The hooks file is SarvTerminal's own: removing deletes it, and no
    /// backup is kept.
    let ownsFile: Bool
    /// Anything the user must do after setup, shown in the confirmation.
    let note: String?

    func isDetected(_ paths: AgentHookPaths) -> Bool {
        paths.fileExists(detection(paths))
    }

    /// Every agent with installable hooks, in the order Settings lists them.
    static let all: [AgentHookIntegration] = [
        claudeCode, codex, gemini, copilot, cursor, droid, qwen,
    ]

    static func forProcess(_ name: String) -> AgentHookIntegration? {
        all.first { $0.processNames.contains(name) }
    }

    static let claudeCode = AgentHookIntegration(
        id: "claude-code", name: "Claude Code", processNames: ["claude"],
        detection: { $0.directory("CLAUDE_CONFIG_DIR", fallback: ".claude") },
        target: { paths in
            AgentHookTarget(
                url: paths.directory("CLAUDE_CONFIG_DIR", fallback: ".claude")
                    .appendingPathComponent("settings.json").resolvingSymlinksInPath(),
                format: GroupedHookFormat(
                    eventsKey: "hooks", specs: claudeSpecs, transport: .terminalSequence, timeout: 5))
        },
        ownsFile: false, note: nil)

    /// Claude Code's events. A Stop that ends on a typed question still turns
    /// needs-you from the screen check.
    static let claudeSpecs: [AgentHookSpec] = [
        AgentHookSpec("SessionStart", .idle),
        AgentHookSpec("UserPromptSubmit", .working),
        AgentHookSpec("PostToolUse", .working),
        AgentHookSpec("PermissionRequest", .blocked),
        AgentHookSpec("PreToolUse", matcher: "AskUserQuestion", .blocked),
        AgentHookSpec("Notification", matcher: "permission_prompt|elicitation_dialog", .blocked),
        AgentHookSpec("Stop", .done),
    ]

    static let codex = AgentHookIntegration(
        id: "codex", name: "Codex CLI", processNames: ["codex"],
        detection: { $0.directory("CODEX_HOME", fallback: ".codex") },
        target: { paths in
            AgentHookTarget(
                url: paths.directory("CODEX_HOME", fallback: ".codex")
                    .appendingPathComponent("hooks.json").resolvingSymlinksInPath(),
                format: GroupedHookFormat(eventsKey: "hooks", specs: [
                    AgentHookSpec("SessionStart", .idle),
                    AgentHookSpec("UserPromptSubmit", .working),
                    AgentHookSpec("PostToolUse", .working),
                    AgentHookSpec("PermissionRequest", .blocked),
                    AgentHookSpec("Stop", .done),
                ], transport: .socket, timeout: 5))
        },
        ownsFile: false,
        note: "Codex runs new hooks only after you trust them: run /hooks in Codex once and trust SarvTerminal's.")

    static let gemini = AgentHookIntegration(
        id: "gemini", name: "Gemini CLI", processNames: ["gemini"],
        detection: { $0.home.appendingPathComponent(".gemini") },
        target: { paths in
            AgentHookTarget(
                url: paths.home.appendingPathComponent(".gemini/settings.json").resolvingSymlinksInPath(),
                format: GroupedHookFormat(eventsKey: "hooks", specs: [
                    AgentHookSpec("SessionStart", .idle),
                    AgentHookSpec("BeforeAgent", .working),
                    AgentHookSpec("AfterTool", .working),
                    AgentHookSpec("Notification", .blocked),
                    AgentHookSpec("AfterAgent", .done),
                ], transport: .socket, timeout: 5000))
        },
        ownsFile: false, note: nil)

    /// Copilot loads every file in its hooks folder, so ours is a file of its own.
    static let copilot = AgentHookIntegration(
        id: "copilot", name: "GitHub Copilot CLI", processNames: ["copilot"],
        detection: { $0.directory("COPILOT_HOME", fallback: ".copilot") },
        target: { paths in
            AgentHookTarget(
                url: paths.directory("COPILOT_HOME", fallback: ".copilot")
                    .appendingPathComponent("hooks/sarvterminal.json"),
                format: FlatHookFormat(specs: [
                    AgentHookSpec("sessionStart", .idle),
                    AgentHookSpec("userPromptSubmitted", .working),
                    AgentHookSpec("postToolUse", .working),
                    AgentHookSpec("permissionRequest", .blocked),
                    AgentHookSpec("agentStop", .done),
                ], commandKey: "bash", timeoutKey: "timeoutSec", timeout: 5, includesType: true))
        },
        ownsFile: true, note: nil)

    /// Detected by the CLI's own config, so a Cursor editor alone doesn't count.
    static let cursor = AgentHookIntegration(
        id: "cursor", name: "Cursor CLI", processNames: ["cursor-agent"],
        detection: { $0.home.appendingPathComponent(".cursor/cli-config.json") },
        target: { paths in
            AgentHookTarget(
                url: paths.home.appendingPathComponent(".cursor/hooks.json").resolvingSymlinksInPath(),
                format: FlatHookFormat(specs: [
                    AgentHookSpec("sessionStart", .idle),
                    AgentHookSpec("beforeSubmitPrompt", .working),
                    AgentHookSpec("preToolUse", .working),
                    AgentHookSpec("stop", .done),
                ], commandKey: "command", timeoutKey: "timeout", timeout: 5, includesType: false))
        },
        ownsFile: false,
        note: "Cursor has no hook for its approval prompts, so those still come from reading the screen.")

    /// Droid reads `hooks.json` when it exists and the `hooks` key of
    /// `settings.json` otherwise, so ours go wherever the user's already are.
    static let droid = AgentHookIntegration(
        id: "droid", name: "Factory Droid", processNames: ["droid"],
        detection: { $0.home.appendingPathComponent(".factory") },
        target: { paths in
            let folder = paths.home.appendingPathComponent(".factory")
            let hooksFile = folder.appendingPathComponent("hooks.json").resolvingSymlinksInPath()
            let usesHooksFile = paths.fileExists(hooksFile)
            return AgentHookTarget(
                url: usesHooksFile
                    ? hooksFile : folder.appendingPathComponent("settings.json").resolvingSymlinksInPath(),
                format: GroupedHookFormat(
                    eventsKey: usesHooksFile ? nil : "hooks", specs: [
                        AgentHookSpec("SessionStart", .idle),
                        AgentHookSpec("UserPromptSubmit", .working),
                        AgentHookSpec("PostToolUse", .working),
                        AgentHookSpec("Notification", matcher: "permission_prompt|elicitation_dialog", .blocked),
                        AgentHookSpec("Stop", .done),
                    ], transport: .socket, timeout: 5))
        },
        ownsFile: false, note: nil)

    static let qwen = AgentHookIntegration(
        id: "qwen", name: "Qwen Code", processNames: ["qwen"],
        detection: { $0.home.appendingPathComponent(".qwen") },
        target: { paths in
            AgentHookTarget(
                url: paths.home.appendingPathComponent(".qwen/settings.json").resolvingSymlinksInPath(),
                format: GroupedHookFormat(eventsKey: "hooks", specs: [
                    AgentHookSpec("SessionStart", .idle),
                    AgentHookSpec("UserPromptSubmit", .working),
                    AgentHookSpec("PostToolUse", .working),
                    AgentHookSpec("PermissionRequest", .blocked),
                    AgentHookSpec("Notification", matcher: "permission_prompt", .blocked),
                    AgentHookSpec("Stop", .done),
                ], transport: .socket, timeout: 5))
        },
        ownsFile: false, note: nil)
}

// MARK: - File edge

extension Notification.Name {
    /// Posted after SarvTerminal installs or removes an agent's hooks, so
    /// every view showing hook state rereads it.
    static let sarvAgentHooksChanged = Notification.Name("SarvAgentHooksChanged")
}

extension AgentHookIntegration {
    /// The hooks file, as shown to the user.
    func displayPath(_ paths: AgentHookPaths = .live) -> String {
        (target(paths).url.path as NSString).abbreviatingWithTildeInPath
    }

    func isInstalled(_ paths: AgentHookPaths = .live) -> Bool {
        let target = target(paths)
        return (try? AgentConfigFile.read(target.url)).map(target.format.isInstalled) ?? false
    }

    func install(_ paths: AgentHookPaths = .live) throws {
        let target = target(paths)
        try AgentConfigFile.update(at: target.url, backup: !ownsFile, target.format.installing)
        NotificationCenter.default.post(name: .sarvAgentHooksChanged, object: nil)
    }

    func remove(_ paths: AgentHookPaths = .live) throws {
        let target = target(paths)
        if ownsFile {
            try AgentConfigFile.delete(target.url)
        } else {
            try AgentConfigFile.update(at: target.url, target.format.removing)
        }
        NotificationCenter.default.post(name: .sarvAgentHooksChanged, object: nil)
    }
}
