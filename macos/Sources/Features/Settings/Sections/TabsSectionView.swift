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
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 320)
            }
            divider
            row("Proxy icon") {
                Picker("", selection: $viewModel.tabs.titlebarProxyIcon) {
                    ForEach(MacosTitlebarProxyIconOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 200)
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
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 260)
            }
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label).frame(width: 130, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var divider: some View { Divider().padding(.leading, 16) }
}
