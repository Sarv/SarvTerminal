import SwiftUI

/// A small "⌘ click to open" hint shown right next to the cursor while hovering
/// an openable link/path. The caller positions it near the mouse location (see
/// `SurfaceView`) — the target text itself is already visible on screen under
/// the cursor, so the hint stays compact.
struct URLHoverBanner: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "command")
                .font(.system(size: 10, weight: .semibold))
            Text("click to open")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
        .fixedSize()
    }
}
