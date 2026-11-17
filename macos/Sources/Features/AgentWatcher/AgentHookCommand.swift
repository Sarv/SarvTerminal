import Foundation

/// The environment SarvTerminal gives every pane so agent hooks know they
/// run inside it and which pane they belong to.
enum AgentHookEnvironment {
    /// "1" in every pane. Hooks that report through the terminal check it.
    static let statusFlag = "SARV_AGENT_STATUS"
    /// The watcher socket's path. Hooks that report through the socket check it.
    static let socket = "SARV_AGENT_SOCKET"
    /// The pane's surface id, which a socket report names.
    static let paneID = "SARV_PANE_ID"

    static func values(socketPath: String, paneID: UUID) -> [String: String] {
        [statusFlag: "1", socket: socketPath, self.paneID: paneID.uuidString]
    }
}

/// The shell command one hook runs to report a state, and the words both
/// transports share.
enum AgentHookCommand {
    /// Marks every SarvTerminal hook in an agent's config, is the OSC 777
    /// title the core reads (`ProgramStatus.hook_marker` in
    /// src/apprt/action.zig), and starts each socket message.
    static let marker = "sarv-agent-status"

    /// How a hook's report reaches the watcher.
    enum Transport: Equatable {
        /// Claude Code writes the hook's `terminalSequence` to the terminal:
        /// an OSC 777 notification the core turns into a program status.
        case terminalSequence
        /// The hook sends one line to the watcher socket, for agents that
        /// run hooks without a terminal.
        case socket
    }

    /// The state word the core's hook marker and the socket understand.
    static func word(_ state: AgentProgramStatus) -> String {
        switch state {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .blocked: return "blocked"
        case .error: return "error"
        }
    }

    /// The state a word names. "clear" means the agent stopped reporting.
    static func state(forWord word: String) -> AgentProgramStatus? {
        switch word {
        case "idle", "clear": return .idle
        case "working": return .working
        case "done": return .done
        case "blocked": return .blocked
        case "error": return .error
        default: return nil
        }
    }

    /// The command for one state. Silent and exit 0 outside SarvTerminal, so
    /// an agent run in another terminal or over SSH is unaffected, and it
    /// prints nothing an agent would read as hook output (the socket form).
    static func command(for state: AgentProgramStatus, via transport: Transport) -> String {
        switch transport {
        case .terminalSequence:
            // `\u001b` and `\u0007` are JSON escapes Claude Code decodes to ESC and BEL.
            let json = #"{"terminalSequence":"\u001b]777;notify;\#(marker);\#(word(state))\u0007"}"#
            return #"[ -n "$\#(AgentHookEnvironment.statusFlag)" ] && printf '%s' '\#(json)' || true"#
        case .socket:
            let socket = AgentHookEnvironment.socket
            return #"[ -n "$\#(socket)" ] && printf '\#(marker) %s \#(word(state))\n' "$\#(AgentHookEnvironment.paneID)""#
                + #" | /usr/bin/nc -U -w 2 "$\#(socket)" >/dev/null 2>&1; true"#
        }
    }

    /// Whether a configured command is one of ours.
    static func isOurs(_ command: String?) -> Bool {
        command?.contains(marker) == true
    }
}

/// One line a hook sent to the watcher socket: `sarv-agent-status <pane> <state>`.
struct AgentStatusMessage: Equatable {
    let paneID: UUID
    let status: AgentProgramStatus

    static func parse(_ line: String) -> AgentStatusMessage? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, fields[0] == AgentHookCommand.marker,
              let paneID = UUID(uuidString: String(fields[1])),
              let status = AgentHookCommand.state(forWord: String(fields[2]))
        else { return nil }
        return AgentStatusMessage(paneID: paneID, status: status)
    }
}
