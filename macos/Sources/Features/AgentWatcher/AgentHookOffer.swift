import Foundation

/// The one-time offer to install an agent's hooks the first time the watcher
/// sees that agent running without them.
enum AgentHookOffer {
    /// Agents the user ticked "Don't ask again" for.
    static let declinedKey = "AgentWatcherDeclinedHookOffers"

    /// The first integration among the running processes that hasn't been
    /// offered this session or declined. `isInstalled` reads a file, so it
    /// runs only for those candidates.
    static func candidate(
        runningProcesses: [String],
        integrations: [AgentHookIntegration] = AgentHookIntegration.all,
        offered: Set<String>,
        declined: Set<String>,
        isInstalled: (AgentHookIntegration) -> Bool
    ) -> AgentHookIntegration? {
        let running = Set(runningProcesses.map(AgentStateReducer.processName))
        return integrations.first { integration in
            !offered.contains(integration.id)
                && !declined.contains(integration.id)
                && !integration.processNames.isDisjoint(with: running)
                && !isInstalled(integration)
        }
    }

    /// The confirmation text, shared with Settings' Set Up button.
    static func setupMessage(for integration: AgentHookIntegration, path: String) -> String {
        var message = "SarvTerminal will add hooks to \(path) so \(integration.name) reports when it starts working, "
            + "needs your answer or permission, and finishes. Your other settings and hooks stay as they are"
            + (integration.ownsFile ? "." : ", and the current file is backed up first.")
            + " The hooks do nothing outside SarvTerminal. Restart running \(integration.name) sessions to pick them up."
        if let note = integration.note { message += "\n\n" + note }
        return message
    }

    // MARK: - Edge

    static var declined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])
    }

    /// Asks once whether to set up `integration`'s hooks.
    @MainActor
    static func present(_ integration: AgentHookIntegration) {
        let path = integration.displayPath()
        SarvAlert.present(
            title: "Set up \(integration.name) hooks?",
            message: "\(integration.name) is running in a tab. "
                + setupMessage(for: integration, path: path)
                + "\n\nYou can do this any time in Settings › AI Agents.",
            buttons: [.init("Set Up", isDefault: true), .init("Not Now", isCancel: true)],
            rememberTitle: "Don't ask again for \(integration.name)"
        ) { result in
            if result.buttonIndex == 0 {
                install(integration)
            } else if result.rememberChecked {
                UserDefaults.standard.set(Array(declined.union([integration.id])).sorted(), forKey: declinedKey)
            }
        }
    }

    /// Installs and reports a failure in an alert.
    @MainActor
    static func install(_ integration: AgentHookIntegration) {
        do {
            try integration.install()
        } catch {
            SarvAlert.present(
                title: "Couldn't set up \(integration.name) hooks",
                message: error.localizedDescription,
                buttons: [.init("OK", isDefault: true)])
        }
    }
}
