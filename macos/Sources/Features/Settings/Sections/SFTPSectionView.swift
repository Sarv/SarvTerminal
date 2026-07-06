import SwiftUI

/// SFTP / file-manager preferences. These live in `SFTPSettings` (UserDefaults),
/// independent of the Ghostty config — so changes apply immediately (no Save).
///
/// Layout mirrors the other settings sections: `DetailView` already renders the
/// section title/subtitle and the scroll container, so this view only emits the
/// cards (no own header / ScrollView). Each change flashes the footer's green
/// "Saved automatically" confirmation via the shared view model.
struct SFTPSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var settings = SFTPSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Editing") {
                row("Auto-save") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Save edits automatically", isOn: $settings.autoSave)
                            .toggleStyle(.checkbox)
                        Text("A moment after you stop typing. When off, save manually with the Save button or ⌘S.")
                            .font(.caption).foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard(title: "Browser") {
                row("Deleting") {
                    Toggle("Confirm before deleting", isOn: $settings.confirmDelete)
                        .toggleStyle(.checkbox)
                }
                divider
                row("Hidden files") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Show hidden files", isOn: $settings.showHidden)
                            .toggleStyle(.checkbox)
                        Text("Show dot-files (e.g. .gitconfig) in the file list.")
                            .font(.caption).foregroundStyle(.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // Each setting applies instantly; mirror that into the footer's green
        // auto-saved confirmation so it's clear the change took effect.
        .onChange(of: settings.autoSave) { _ in viewModel.flashSaved() }
        .onChange(of: settings.confirmDelete) { _ in viewModel.flashSaved() }
        .onChange(of: settings.showHidden) { _ in viewModel.flashSaved() }
    }

    private func row<C: View>(_ label: String, @ViewBuilder control: () -> C) -> some View {
        settingsRow(label, alignment: .top, control: control)
    }

    private var divider: some View { SettingsDivider() }
}
