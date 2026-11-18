import SwiftUI

/// Small ✕ that turns red on hover, the same affordance as the tab chip's
/// close button. Used for pane close and the inspector close.
struct HoverCloseButton: View {
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Color.white : .white.opacity(0.75))
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Color.red : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .hoverTip(help)
    }
}
