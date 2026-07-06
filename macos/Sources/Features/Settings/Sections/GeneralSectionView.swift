import SwiftUI

struct GeneralSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @AppStorage("SarvRestoreSession") private var restoreSession = true
    @AppStorage("SarvNewTabDirectory") private var newTabDirectory = ""
    @AppStorage(HostConnectClickMode.storageKey)
    private var hostsConnectClick: HostConnectClickMode = .double

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            startupCard
            sessionCard
            behaviorCard
            terminalCard
            hostsCard
            clipboardCard
            scrollbackCard
        }
    }

    private var hostsCard: some View {
        SettingsCard(title: "Hosts") {
            row("Hosts & sessions connect on") {
                Picker("", selection: $hostsConnectClick) {
                    ForEach(HostConnectClickMode.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    private var sessionCard: some View {
        SettingsCard(title: "Session") {
            row("Restore tabs") {
                Toggle("Reopen last session's tabs when SarvTerminal launches",
                       isOn: $restoreSession)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var terminalCard: some View {
        SettingsCard(title: "Terminal") {
            row("Progress bar") {
                Toggle("Show a running-command progress bar under the tab",
                       isOn: $viewModel.general.showProgressBar)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var startupCard: some View {
        SettingsCard(title: "Startup") {
            row("Command") {
                HStack(spacing: 8) {
                    TextField("/bin/zsh, /opt/homebrew/bin/fish, …",
                              text: $viewModel.general.command)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .font(.system(.body, design: .monospaced))
                    if !viewModel.general.command.isEmpty {
                        Button("Reset") { viewModel.general.command = "" }
                            .controlSize(.small)
                    }
                }
            }
            divider
            row("Working directory") {
                HStack(spacing: 8) {
                    TextField("home, inherit, or a path", text: $viewModel.general.workingDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .font(.system(.body, design: .monospaced))
                    if !viewModel.general.workingDirectory.isEmpty {
                        Button("Reset") { viewModel.general.workingDirectory = "" }
                            .controlSize(.small)
                    }
                }
            }
            divider
            row("New tab directory") {
                HStack(spacing: 8) {
                    TextField("home (default), or a path", text: $newTabDirectory)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                        .font(.system(.body, design: .monospaced))
                    if !newTabDirectory.isEmpty {
                        Button("Reset") { newTabDirectory = "" }
                            .controlSize(.small)
                    }
                }
            }
            divider
            row("Confirm close") {
                Picker("", selection: $viewModel.general.confirmClose) {
                    ForEach(ConfirmCloseOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 280, alignment: .leading)
            }
            divider
            row("Quit after last window") {
                Toggle("Quit Ghostty when the last window closes",
                       isOn: $viewModel.general.quitAfterLastWindowClosed)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var behaviorCard: some View {
        SettingsCard(title: "Mouse & Focus") {
            row("Mouse") {
                Toggle("Hide mouse pointer while typing",
                       isOn: $viewModel.general.mouseHideWhileTyping)
                    .toggleStyle(.checkbox)
            }
            divider
            row("Focus") {
                Toggle("Focus follows mouse",
                       isOn: $viewModel.general.focusFollowsMouse)
                    .toggleStyle(.checkbox)
            }
            divider
            row("Scroll speed") {
                HStack(spacing: 12) {
                    Slider(value: $viewModel.general.mouseScrollMultiplier, in: 0.1...10, step: 0.1)
                        .frame(maxWidth: 280)
                    Text(String(format: "%.1f×", viewModel.general.mouseScrollMultiplier))
                        .font(.callout).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            divider
            row("Links") {
                Toggle("Detect URLs (⌘-click to open)",
                       isOn: $viewModel.general.linkURL)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var clipboardCard: some View {
        SettingsCard(title: "Clipboard") {
            row("Copy on select") {
                Picker("", selection: $viewModel.general.copyOnSelect) {
                    ForEach(CopyOnSelectOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 260, alignment: .leading)
            }
            divider
            row("Clipboard read") {
                Picker("", selection: $viewModel.general.clipboardRead) {
                    ForEach(ClipboardAccessOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
            }
            divider
            row("Clipboard write") {
                Picker("", selection: $viewModel.general.clipboardWrite) {
                    ForEach(ClipboardAccessOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
            }
            divider
            row("Paste protection") {
                Toggle("Warn before pasting multi-line text that could run commands",
                       isOn: $viewModel.general.clipboardPasteProtection)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var scrollbackCard: some View {
        SettingsCard(title: "Scrollback") {
            row("Buffer size") {
                HStack(spacing: 12) {
                    Slider(value: $viewModel.general.scrollbackLimitMB, in: 1...100, step: 1)
                        .frame(maxWidth: 320)
                    Text(String(format: "%.0f MB", viewModel.general.scrollbackLimitMB))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        settingsRow(label, control: control)
    }

    private var divider: some View { SettingsDivider() }
}
