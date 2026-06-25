import SwiftUI

/// Form for the Cursor section.
///
/// Scope:
/// - **Style** — block / bar / underline / hollow block (visual previews next to each option)
/// - **Blink** — System default / Always blink / Don't blink
/// - **Text color** — color of text *under* the cursor (when cursor color inverts the cell)
/// - **Opacity** — 0–100%
/// - **Behavior** — click anywhere in the line to move cursor (needs shell integration)
struct CursorSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            styleCard
            colorCard
            opacityCard
            behaviorCard
        }
    }

    // MARK: - Style card

    private var styleCard: some View {
        SettingsCard(title: "Style") {
            row("Cursor style") {
                HStack(spacing: 10) {
                    ForEach(CursorStyleOption.allCases) { option in
                        styleChip(option)
                    }
                }
            }
            divider
            row("Blink") {
                Picker("", selection: $viewModel.cursor.blink) {
                    ForEach(CursorBlinkOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
    }

    /// A tappable mini-card showing a visual representation of the cursor
    /// style + the label. The selected one gets an accent border.
    private func styleChip(_ option: CursorStyleOption) -> some View {
        let isSelected = viewModel.cursor.style == option
        return Button {
            viewModel.cursor.style = option
        } label: {
            VStack(spacing: 6) {
                CursorStylePreview(style: option)
                    .frame(width: 60, height: 30)
                Text(option.label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Color card

    private var colorCard: some View {
        SettingsCard(title: "Text Color") {
            row("Under-cursor text") {
                HStack(spacing: 12) {
                    Toggle("Override", isOn: $viewModel.cursor.useTextColor)
                        .toggleStyle(.switch)
                        .labelsHidden()
                    Text(viewModel.cursor.useTextColor ? "Custom" : "Default")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .leading)
                    if viewModel.cursor.useTextColor {
                        ColorSwatchPicker(color: $viewModel.cursor.textColor)
                    }
                }
            }
        }
    }

    // MARK: - Opacity card

    private var opacityCard: some View {
        SettingsCard(title: "Opacity") {
            row("Cursor opacity") {
                HStack(spacing: 12) {
                    Slider(value: $viewModel.cursor.opacity, in: 0...1)
                        .frame(maxWidth: 320)
                    Text(String(format: "%.0f%%", viewModel.cursor.opacity * 100))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Behavior card

    private var behaviorCard: some View {
        SettingsCard(title: "Behavior") {
            row("Click to move") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Move cursor by clicking in the prompt line",
                           isOn: $viewModel.cursor.clickToMove)
                        .toggleStyle(.checkbox)
                    Text("Requires shell integration. Sends arrow keys to move from the current cursor position to where you clicked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Row helpers

    private func row<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        settingsRow(label, control: control)
    }

    private var divider: some View { SettingsDivider() }
}

/// Visual preview of a cursor style — a small rectangle showing roughly what
/// the cursor will look like on a terminal cell. Just shape, no animation.
struct CursorStylePreview: View {
    let style: CursorStyleOption

    var body: some View {
        ZStack(alignment: .center) {
            // Faint cell background to give context
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
            // A faint "x" for the underlying glyph
            Text("x")
                .font(.system(size: 16, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
            // The actual cursor shape
            shape
                .foregroundStyle(.tint)
        }
    }

    @ViewBuilder
    private var shape: some View {
        switch style {
        case .block:
            Rectangle()
                .frame(width: 14, height: 22)
                .opacity(0.85)
        case .bar:
            Rectangle()
                .frame(width: 2, height: 22)
        case .underline:
            VStack {
                Spacer()
                Rectangle()
                    .frame(width: 14, height: 2)
            }
            .frame(height: 22)
        case .blockHollow:
            Rectangle()
                .stroke(Color.accentColor, lineWidth: 1.5)
                .frame(width: 14, height: 22)
        }
    }
}
