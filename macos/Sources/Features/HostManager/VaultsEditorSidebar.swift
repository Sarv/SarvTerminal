import SwiftUI

/// Trailing side panel that overlays the current screen with a dimmed,
/// click-to-dismiss scrim — the "Edit host" pattern from the SSH connection
/// popup. Hosts any editor content (host editor, group editor, …) so the
/// screen underneath stays visible and navigation is never lost.
struct VaultsEditorSidebar<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            // Dimmed scrim over the rest of the screen; click to dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            content
                .frame(width: 400)
                .frame(maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(alignment: .leading) {
                    Divider()
                }
        }
    }
}
