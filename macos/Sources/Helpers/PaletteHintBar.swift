import SwiftUI

/// The keyboard-hint footer shared across palettes and pickers: an optional
/// leading caption on the left, and a row of key-hint chips on the right
/// (↑↓ navigate · ⏎ open · Esc cancel by default). Reused so every palette
/// advertises the same affordances with identical styling — pair it with
/// `KeyNavigableList`.
struct PaletteHintBar: View {
    /// Optional caption shown on the leading edge (e.g. "Quick connect, or pick
    /// a saved host"). Omit for just the key hints.
    var label: String? = nil
    /// The key-hint chips, in order.
    var hints: [String] = ["↑↓ navigate", "⏎ open", "Esc cancel"]

    var body: some View {
        HStack {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondaryText)
            }
            Spacer()
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(.secondaryText)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
