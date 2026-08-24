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
                        .foregroundStyle(.secondaryText)
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
                VStack(alignment: .leading, spacing: 4) {
                    limitPicker(
                        selection: $viewModel.general.scrollbackLimitBytes,
                        presets: ScrollbackLimit.bytePresets,
                        label: ScrollbackLimit.byteLabel
                    )
                    caption(ScrollbackLimit.isUnlimited(viewModel.general.scrollbackLimitBytes)
                            ? "History grows until memory runs out — under pressure macOS can terminate the app. Applies per terminal surface."
                            : "Applies per terminal surface. The oldest history is trimmed once this much memory is used.")
                }
            }
            divider
            row("Line limit") {
                VStack(alignment: .leading, spacing: 4) {
                    limitPicker(
                        selection: $viewModel.general.scrollbackLimitLines,
                        presets: ScrollbackLimit.linePresets,
                        label: ScrollbackLimit.lineLabel
                    )
                    caption(ScrollbackLimit.isUnlimited(viewModel.general.scrollbackLimitLines)
                            ? "No line cap — the buffer size above decides when history is trimmed."
                            : "Whichever limit is reached first trims history. Wrapped rows count individually, so the real cap lands slightly higher.")
                }
            }
            divider
            row("Compression") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Compress idle scrollback to save memory",
                           isOn: $viewModel.general.scrollbackCompression)
                        .toggleStyle(.checkbox)
                    Text("Compresses off-screen history while the terminal is idle, cutting memory use. It's restored automatically when you scroll back.")
                        .font(.caption).foregroundStyle(.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Menu picker over `presets`, plus the configured value when a hand-edited
    /// config set something off-preset (so it's shown, not silently snapped).
    private func limitPicker(
        selection: Binding<UInt>,
        presets: [UInt],
        label: @escaping (UInt) -> String
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(ScrollbackLimit.options(presets: presets, current: selection.wrappedValue),
                    id: \.self) { value in
                Text(label(value)).tag(value)
            }
        }
        .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        settingsRow(label, control: control)
    }

    private var divider: some View { SettingsDivider() }
}
