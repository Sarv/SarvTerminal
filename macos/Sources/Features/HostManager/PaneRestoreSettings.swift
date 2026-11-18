import Foundation

/// Whether a session save also records each pane's running command.
enum PaneCommandCapture: Equatable {
    /// Library saves (⌘S) and closed-tab snapshots: layout only.
    case skip
    /// Relaunch snapshot. `fresh` re-reads every process instead of using a
    /// recent capture.
    case capture(fresh: Bool)
}

/// The "Resume running commands" preference and how a saved command becomes
/// typed input for the reopened pane.
enum PaneRestoreSettings {
    static let key = "SarvRestoreRunningCommands"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// The text to type into the new shell, with Enter so it runs again.
    static func initialInput(_ command: SavedSession.RestoreCommand) -> String? {
        let line = command.commandLine
        guard isEnabled, !line.isEmpty, !Ghostty.Shell.containsControlCharacters(line) else { return nil }
        return line + "\n"
    }
}
