import SwiftUI

struct ShellIntegrationSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// Tags currently enabled, parsed from the comma-separated string.
    private var enabledTags: Set<String> {
        Set(viewModel.shellIntegration.features
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("no-") })
    }

    /// `no-foo` markers in the features string mean explicitly off.
    private var disabledTags: Set<String> {
        Set(viewModel.shellIntegration.features
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.hasPrefix("no-") }
            .map { String($0.dropFirst(3)) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            integrationCard
            featuresCard
        }
    }

    private var integrationCard: some View {
        SettingsCard(title: "Integration") {
            row("Shell") {
                Picker("", selection: $viewModel.shellIntegration.integration) {
                    ForEach(ShellIntegrationOption.allCases) { opt in
                        Text(opt.label).tag(opt)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: 240)
            }
        }
    }

    private var featuresCard: some View {
        SettingsCard(title: "Features") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(kShellIntegrationFeatures, id: \.tag) { feature in
                    featureRow(feature)
                    if feature.tag != kShellIntegrationFeatures.last?.tag {
                        divider
                    }
                }
            }
        }
    }

    /// Effective on/off state for a feature: an explicit override in the
    /// config wins; otherwise fall back to Ghostty's default for that feature.
    private func isOn(_ feature: ShellIntegrationFeature) -> Bool {
        if disabledTags.contains(feature.tag) { return false }
        if enabledTags.contains(feature.tag) { return true }
        return feature.defaultOn
    }

    private func featureRow(_ feature: ShellIntegrationFeature) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Toggle(isOn: Binding(
                get: { isOn(feature) },
                set: { newValue in setFeature(feature.tag, enabled: newValue) }
            )) {
                EmptyView()
            }
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.label)
                    .fontWeight(.medium)
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(feature.tag)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func setFeature(_ tag: String, enabled: Bool) {
        var on = enabledTags
        var off = disabledTags
        on.remove(tag)
        off.remove(tag)
        // Only record an override when it differs from Ghostty's default, so
        // the config stays minimal (and unlisted features keep their defaults).
        let defaultOn = kShellIntegrationFeatures.first { $0.tag == tag }?.defaultOn ?? false
        if enabled != defaultOn {
            if enabled { on.insert(tag) } else { off.insert(tag) }
        }
        let parts = on.sorted() + off.sorted().map { "no-\($0)" }
        viewModel.shellIntegration.features = parts.joined(separator: ", ")
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
