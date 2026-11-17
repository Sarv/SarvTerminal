import Foundation

/// One hook: the agent event, its matcher (nil for none), and the state it reports.
struct AgentHookSpec: Equatable {
    let event: String
    let matcher: String?
    let state: AgentProgramStatus

    init(_ event: String, matcher: String? = nil, _ state: AgentProgramStatus) {
        self.event = event
        self.matcher = matcher
        self.state = state
    }
}

/// How one agent's config file holds hooks. Pure functions over the decoded
/// JSON object; `AgentConfigFile` does the reading and writing.
protocol AgentHookFormat {
    /// The config without any SarvTerminal hooks. Everything else stays as it
    /// was; an event or container left empty by the removal goes.
    func removing(from config: [String: Any]) -> [String: Any]
    /// The config with exactly the current hooks added. Idempotent: an older
    /// copy of ours is replaced, never doubled.
    func installing(into config: [String: Any]) -> [String: Any]
}

extension AgentHookFormat {
    /// Whether the config holds the current hooks exactly.
    func isInstalled(in config: [String: Any]) -> Bool {
        NSDictionary(dictionary: config).isEqual(to: installing(into: config))
    }
}

/// Claude Code's shape, also used by Codex, Gemini CLI, Qwen Code and
/// Factory Droid: `{event: [{matcher?, hooks: [{type, command, timeout}]}]}`,
/// under `eventsKey` or at the top level when it is nil.
struct GroupedHookFormat: AgentHookFormat {
    let eventsKey: String?
    let specs: [AgentHookSpec]
    let transport: AgentHookCommand.Transport
    /// In the agent's own unit: seconds for most, milliseconds for Gemini.
    let timeout: Int

    func group(for spec: AgentHookSpec) -> [String: Any] {
        let command = AgentHookCommand.command(for: spec.state, via: transport)
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
        if let matcher = spec.matcher { group["matcher"] = matcher }
        return group
    }

    private static func isOurs(_ handler: Any) -> Bool {
        AgentHookCommand.isOurs((handler as? [String: Any])?["command"] as? String)
    }

    func removing(from config: [String: Any]) -> [String: Any] {
        let events = eventsKey.map { config[$0] as? [String: Any] } ?? config
        guard let events else { return config }
        var keptEvents: [String: Any] = [:]
        for (event, value) in events {
            guard let groups = value as? [Any] else {
                keptEvents[event] = value
                continue
            }
            let keptGroups: [Any] = groups.compactMap { element in
                guard var group = element as? [String: Any],
                      let handlers = group["hooks"] as? [Any],
                      handlers.contains(where: Self.isOurs)
                else { return element }
                let keptHandlers = handlers.filter { !Self.isOurs($0) }
                if keptHandlers.isEmpty { return nil }
                group["hooks"] = keptHandlers
                return group
            }
            if !keptGroups.isEmpty || groups.isEmpty { keptEvents[event] = keptGroups }
        }
        guard let eventsKey else { return keptEvents }
        var next = config
        next[eventsKey] = keptEvents.isEmpty ? nil : keptEvents
        return next
    }

    func installing(into config: [String: Any]) -> [String: Any] {
        let cleaned = removing(from: config)
        var events = eventsKey.map { cleaned[$0] as? [String: Any] ?? [:] } ?? cleaned
        for spec in specs {
            events[spec.event] = (events[spec.event] as? [Any] ?? []) + [group(for: spec)]
        }
        guard let eventsKey else { return events }
        var next = cleaned
        next[eventsKey] = events
        return next
    }
}

/// Cursor's and GitHub Copilot CLI's shape:
/// `{"version": 1, "hooks": {event: [{<commandKey>, <timeoutKey>, matcher?}]}}`.
struct FlatHookFormat: AgentHookFormat {
    let specs: [AgentHookSpec]
    /// "command" for Cursor, "bash" for Copilot.
    let commandKey: String
    /// "timeout" for Cursor, "timeoutSec" for Copilot; both in seconds.
    let timeoutKey: String
    let timeout: Int
    /// Copilot entries carry `"type": "command"`.
    let includesType: Bool

    func entry(for spec: AgentHookSpec) -> [String: Any] {
        var entry: [String: Any] = [
            commandKey: AgentHookCommand.command(for: spec.state, via: .socket),
            timeoutKey: timeout,
        ]
        if includesType { entry["type"] = "command" }
        if let matcher = spec.matcher { entry["matcher"] = matcher }
        return entry
    }

    private func isOurs(_ entry: Any) -> Bool {
        AgentHookCommand.isOurs((entry as? [String: Any])?[commandKey] as? String)
    }

    func removing(from config: [String: Any]) -> [String: Any] {
        guard let events = config["hooks"] as? [String: Any] else { return config }
        var keptEvents: [String: Any] = [:]
        for (event, value) in events {
            guard let entries = value as? [Any] else {
                keptEvents[event] = value
                continue
            }
            let kept = entries.filter { !isOurs($0) }
            if !kept.isEmpty || entries.isEmpty { keptEvents[event] = kept }
        }
        var next = config
        next["hooks"] = keptEvents.isEmpty ? nil : keptEvents
        return next
    }

    func installing(into config: [String: Any]) -> [String: Any] {
        var next = removing(from: config)
        var events = next["hooks"] as? [String: Any] ?? [:]
        for spec in specs {
            events[spec.event] = (events[spec.event] as? [Any] ?? []) + [entry(for: spec)]
        }
        next["hooks"] = events
        if next["version"] == nil { next["version"] = 1 }
        return next
    }
}
