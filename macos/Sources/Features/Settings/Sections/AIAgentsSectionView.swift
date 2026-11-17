import SwiftUI

/// Settings → AI Agents. Turns the agent watcher on or off, and installs the
/// hooks that let each agent report exactly when it is working, needs you,
/// or is done.
struct AIAgentsSectionView: View {
    @ObservedObject private var store: AgentWatcherStore = .shared
    @AppStorage(AgentDoneHold.key) private var doneHold: AgentDoneHold = AgentDoneHold.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            watcherCard
            if store.isEnabled { hooksCard }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private var watcherCard: some View {
        SettingsCard(title: "AI Agent Watcher") {
            settingsRow("Enable") {
                Toggle("", isOn: Binding(get: { store.isEnabled }, set: store.setEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .help("Show the robot icon in the tab bar and watch every tab's agent")
            }
            if store.isEnabled {
                SettingsDivider()
                settingsRow("Show done for") {
                    Picker("", selection: $doneHold) {
                        ForEach(AgentDoneHold.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200, alignment: .leading)
                    .help("How long a finished agent's tab stays done after you look at it, before it turns idle")
                }
            }
            SettingsDivider()
            Text("Shows which tabs have an AI agent working, waiting for you, or done, "
                 + "with a dot on each tab and a reminder while one needs you. "
                 + "When off, the icon and dots are hidden and nothing is watched.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsMetrics.horizontalPadding)
                .padding(.vertical, SettingsMetrics.verticalPadding)
        }
    }

    private var hooksCard: some View {
        SettingsCard(title: "Agent Hooks") {
            Text("Without hooks the watcher reads progress, notifications and the screen, "
                 + "which can't always tell waiting for you from done. Hooks make the agent "
                 + "report its state itself. They only act inside SarvTerminal.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsMetrics.horizontalPadding)
                .padding(.vertical, SettingsMetrics.verticalPadding)
            ForEach(AgentHookIntegration.all) { integration in
                SettingsDivider()
                AgentHookRow(integration: integration)
            }
            SettingsDivider()
            settingsRow("All detected agents") {
                HStack {
                    Spacer()
                    Button("Set Up All", action: confirmSetUpAll)
                        .help("Add hooks for every agent found on this Mac that doesn't have them yet")
                }
            }
        }
    }

    private func confirmSetUpAll() {
        let pending = AgentHookIntegration.all.filter { $0.isDetected(.live) && !$0.isInstalled() }
        guard !pending.isEmpty else {
            SarvAlert.present(
                title: "Nothing to set up",
                message: "Every agent found on this Mac already has SarvTerminal's hooks.",
                buttons: [.init("OK", isDefault: true)])
            return
        }
        let list = pending.map { "• \($0.name): \($0.displayPath())" }.joined(separator: "\n")
        let notes = pending.compactMap(\.note).map { "\n\n" + $0 }.joined()
        SarvAlert.present(
            title: "Set up hooks for \(pending.count) agent\(pending.count == 1 ? "" : "s")?",
            message: "SarvTerminal will add its hooks to:\n\(list)\n\nYour other settings and hooks stay as they are, "
                + "and shared files are backed up first. The hooks do nothing outside SarvTerminal. "
                + "Restart running agent sessions to pick them up." + notes,
            buttons: [.init("Set Up All", isDefault: true), .init("Cancel", isCancel: true)]
        ) { result in
            guard result.buttonIndex == 0 else { return }
            let failures = pending.compactMap { integration -> String? in
                do {
                    try integration.install()
                    return nil
                } catch {
                    return "\(integration.name): \(error.localizedDescription)"
                }
            }
            guard !failures.isEmpty else { return }
            SarvAlert.present(
                title: "Some hooks couldn't be set up",
                message: failures.joined(separator: "\n\n"),
                buttons: [.init("OK", isDefault: true)])
        }
    }
}

/// One agent's hook state with an install or remove button.
private struct AgentHookRow: View {
    let integration: AgentHookIntegration
    @State private var installed = false
    @State private var detected = true

    var body: some View {
        settingsRow(integration.name) {
            HStack(spacing: 6) {
                Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(installed ? Color.green : .secondary)
                    .help(installed ? "Hooks installed" : "Hooks not installed")
                Text(installed ? "Installed" : detected ? "Not set up" : "Not found on this Mac")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(installed ? "Remove" : "Set Up", action: confirm)
                    .help(installed
                          ? "Remove SarvTerminal's hooks from \(integration.displayPath())"
                          : "Add hooks to \(integration.displayPath())")
            }
        }
        .onAppear(perform: refresh)
        // Settings may already be open, or kept alive, when hooks are set up
        // from the watcher's one-time offer or Set Up All.
        .onReceive(NotificationCenter.default.publisher(for: .sarvAgentHooksChanged)) { _ in refresh() }
    }

    private func refresh() {
        installed = integration.isInstalled()
        detected = integration.isDetected(.live)
    }

    private func confirm() {
        let remove = installed
        let path = integration.displayPath()
        let message = remove
            ? "SarvTerminal will remove only its own hooks from \(path). Your other settings and hooks stay as they are."
            : AgentHookOffer.setupMessage(for: integration, path: path)
        SarvAlert.present(
            title: remove ? "Remove \(integration.name) hooks?" : "Set up \(integration.name) hooks?",
            message: message,
            buttons: [
                .init(remove ? "Remove Hooks" : "Add Hooks", isDefault: true, isDestructive: remove),
                .init("Cancel", isCancel: true),
            ]
        ) { result in
            guard result.buttonIndex == 0 else { return }
            apply(remove: remove)
        }
    }

    private func apply(remove: Bool) {
        if remove {
            do {
                try integration.remove()
            } catch {
                SarvAlert.present(
                    title: "Couldn't remove the hooks",
                    message: error.localizedDescription,
                    buttons: [.init("OK", isDefault: true)])
            }
        } else {
            AgentHookOffer.install(integration)
        }
        refresh()
    }
}
