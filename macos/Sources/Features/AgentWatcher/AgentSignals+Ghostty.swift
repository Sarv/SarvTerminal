import GhosttyKit

extension AgentProgramStatus {
    /// Reads the core's OSC 7501 state. Nil for a value this build doesn't know.
    init?(_ state: ghostty_action_program_status_state_e) {
        switch state {
        case GHOSTTY_PROGRAM_STATUS_IDLE: self = .idle
        case GHOSTTY_PROGRAM_STATUS_WORKING: self = .working
        case GHOSTTY_PROGRAM_STATUS_DONE: self = .done
        case GHOSTTY_PROGRAM_STATUS_BLOCKED: self = .blocked
        case GHOSTTY_PROGRAM_STATUS_ERROR: self = .error
        default: return nil
        }
    }
}

extension AgentProgress {
    /// OSC 9;4: clearing the bar is `cleared`, an error is `error`, and any
    /// shown bar (set, spinner, paused) means the program is busy.
    init(_ state: Ghostty.Action.ProgressReport.State) {
        switch state {
        case .remove: self = .cleared
        case .error: self = .error
        case .set, .indeterminate, .pause: self = .active
        }
    }
}
