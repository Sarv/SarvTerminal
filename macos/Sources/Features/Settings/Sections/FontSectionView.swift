import SwiftUI

/// Form for the Font section.
///
/// **B.4 scope (current):** family, size, features (single-value for each).
/// **Follow-up:** multi-family editor (`font-family` is a RepeatableString),
/// bold/italic overrides, font variations, OpenType features chip editor.
struct FontSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            familyCard
            sizeCard
            featuresCard
            advancedCard
        }
    }

    // MARK: - Advanced

    private var advancedCard: some View {
        SettingsCard(title: "Advanced") {
            row("Thicken") {
                Toggle("Synthetic bold — thicken glyphs (helps thin fonts)",
                       isOn: $viewModel.font.thicken)
                    .toggleStyle(.checkbox)
            }
            divider
            row("Cell width") {
                TextField("e.g. 10% or -1", text: $viewModel.font.adjustCellWidth)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .help("adjust-cell-width — nudge cell width (percent or points).")
            }
            divider
            row("Cell height") {
                TextField("e.g. 10% or -1", text: $viewModel.font.adjustCellHeight)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .help("adjust-cell-height — nudge cell/line height (percent or points).")
            }
        }
    }

    // MARK: - Family

    private var familyCard: some View {
        SettingsCard(title: "Family") {
            row("Font family") {
                FontFamilyPicker(family: $viewModel.font.family)
            }
        }
    }

    // MARK: - Size

    private var sizeCard: some View {
        SettingsCard(title: "Size") {
            row("Font size") {
                HStack(spacing: 12) {
                    Slider(
                        value: $viewModel.font.size,
                        in: 8...32,
                        step: 0.5
                    )
                    .frame(maxWidth: 320)
                    Text(String(format: "%.1f pt", viewModel.font.size))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Stepper("", value: $viewModel.font.size, in: 6...64, step: 0.5)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - Features

    private var featuresCard: some View {
        SettingsCard(title: "Features") {
            row("OpenType features") {
                FontFeaturePicker(features: $viewModel.font.feature)
            }
        }
    }

    // MARK: - Row helpers (mirrors AppearanceSectionView)

    private func row<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .frame(width: 130, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var divider: some View {
        Divider().padding(.leading, 16)
    }
}
