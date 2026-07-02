import AppKit

extension NSImage {
    /// The app's clean, centered brand logo (no DEV badge), rendered from the
    /// release app icon art. Used as the icon for alerts and dialogs so every
    /// confirmation popup looks symmetric and consistent across debug and
    /// release builds — the Dock icon keeps its build-specific badge, but
    /// in-app UI always shows the centered logo.
    static var sarvBrandIcon: NSImage? {
        NSImage(named: "AppIconImage")
    }
}
