import AppKit

// MARK: Ghostty Delegate

/// This implements the Ghostty app delegate protocol which is used by the Ghostty
/// APIs for app-global information.
extension AppDelegate: Ghostty.Delegate {
    func ghosttySurface(id: UUID) -> Ghostty.SurfaceView? {
        // Embedded Vaults tabs — the primary home of surfaces in this app.
        // (Without this, a dragged pane's Transferable import resolves to nil
        // and drops silently no-op.)
        for tab in VaultsTabsModel.shared.terminals {
            for surface in tab.surfaceTree where surface.id == id {
                return surface
            }
        }

        // Native terminal windows (quick terminal, standalone windows).
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else {
                continue
            }

            for surface in controller.surfaceTree where surface.id == id {
                return surface
            }
        }

        return nil
    }
}
