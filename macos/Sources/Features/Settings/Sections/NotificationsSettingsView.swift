import SwiftUI

/// Settings ▸ Notifications: master switch, alert sound, and per-category
/// toggles for SarvTerminal's app-level notifications.
struct NotificationsSettingsView: View {
    @ObservedObject private var settings = SarvNotificationSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            generalCard
            soundCard
            eventsCard
        }
    }

    private var generalCard: some View {
        SettingsCard(title: "Notifications") {
            row("Enable") {
                Toggle("Show macOS notifications for app events", isOn: $settings.enabled)
                    .toggleStyle(.checkbox)
            }
        }
    }

    private var soundCard: some View {
        SettingsCard(title: "Sound") {
            row("Alert sound") {
                Toggle("Play a sound when a notification arrives", isOn: $settings.soundEnabled)
                    .toggleStyle(.checkbox)
                    .disabled(!settings.enabled)
            }
            divider
            row("Sound") {
                HStack(spacing: 8) {
                    Picker("", selection: .constant(0)) {
                        Text("Default").tag(0)
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .fixedSize()
                    .disabled(true)
                    .help("More sounds coming soon.")
                    Button {
                        SarvNotifications.shared.previewSound()
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Preview this sound")
                }
            }
        }
    }

    private var eventsCard: some View {
        SettingsCard(title: "Notify me about") {
            ForEach(Array(SarvNotificationCategory.allCases.enumerated()), id: \.element.id) { index, category in
                if index > 0 { divider }
                row(category.label) {
                    Toggle(category.detail, isOn: binding(for: category))
                        .toggleStyle(.checkbox)
                        .disabled(!settings.enabled)
                }
            }
        }
    }

    private func binding(for category: SarvNotificationCategory) -> Binding<Bool> {
        Binding(
            get: { settings.categoryOn(category) },
            set: { settings.setCategory($0, category) }
        )
    }

    // MARK: - Row helpers (mirror the other settings sections)

    private func row<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        settingsRow(label, control: control)
    }

    private var divider: some View { SettingsDivider() }
}
