import SwiftUI

/// Settings design system — the single source of truth for how every settings
/// row, divider and card is laid out. Think of it like a shared stylesheet:
/// change a metric here and every settings screen updates in lockstep, and any
/// new setting that uses `SettingsRow` / `SettingsCard` automatically inherits
/// the same alignment without re-specifying widths or padding.
enum SettingsMetrics {
    /// Fixed width of the leading label column. Keeps every control across all
    /// sections starting at the same x position.
    static let labelWidth: CGFloat = 170
    /// Gap between the label column and the control.
    static let rowSpacing: CGFloat = 16
    /// Horizontal inset of a row's content from the card edge.
    static let horizontalPadding: CGFloat = 16
    /// Vertical inset (top/bottom) of a row's content.
    static let verticalPadding: CGFloat = 12
    /// Corner radius of a settings card.
    static let cardCornerRadius: CGFloat = 10
}

/// One labelled settings row: a fixed-width label on the leading edge, a control
/// next to it, then trailing flexible space so controls all start at the same x.
///
/// `alignment` is `.center` for single-line controls and `.top` for tall /
/// multi-line controls (e.g. a help string that wraps under a checkbox).
///
/// Implemented as a `@ViewBuilder` function rather than a `View` struct so the
/// control closure is consumed inline — sections can forward their own
/// (non-escaping) builder straight through without an `@escaping` dance.
@ViewBuilder
func settingsRow<Control: View>(
    _ label: String,
    alignment: VerticalAlignment = .center,
    @ViewBuilder control: () -> Control
) -> some View {
    HStack(alignment: alignment, spacing: SettingsMetrics.rowSpacing) {
        Text(label)
            .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
        control()
        Spacer(minLength: 0)
    }
    .padding(.horizontal, SettingsMetrics.horizontalPadding)
    .padding(.vertical, SettingsMetrics.verticalPadding)
}

/// Hairline separator between two rows inside a card, inset to align with the
/// row content rather than the label column edge.
struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, SettingsMetrics.horizontalPadding)
    }
}

/// Visual grouping for a related set of settings. Title at top, rounded
/// container, full-width.
struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            )
        }
    }
}
