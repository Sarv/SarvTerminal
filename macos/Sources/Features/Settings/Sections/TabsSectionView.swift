import SwiftUI

struct TabsSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            titlebarCard
            newTabCard
        }
    }

    private var titlebarCard: some View {
        SettingsCard(title: "macOS Titlebar") {
            row("Style") {
                Picker("", selection: $viewModel.tabs.titlebarStyle) {
                    ForEach(MacosTitlebarStyleOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 320, alignment: .leading)
            }
            divider
            row("Proxy icon") {
                Picker("", selection: $viewModel.tabs.titlebarProxyIcon) {
                    ForEach(MacosTitlebarProxyIconOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200, alignment: .leading)
            }
        }
    }

    private var newTabCard: some View {
        SettingsCard(title: "New Tab") {
            row("Position") {
                Picker("", selection: $viewModel.tabs.newTabPosition) {
                    ForEach(NewTabPositionOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 260, alignment: .leading)
            }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        settingsRow(label, control: control)
    }

    private var divider: some View { SettingsDivider() }
}
