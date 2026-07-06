import SwiftUI

// Centralized, theme-adaptive text colors used everywhere in place of SwiftUI's
// built-in `.secondary` / `.tertiary` hierarchical styles.
//
// The system hierarchical styles render at fixed, very low opacities (~55% and
// ~25% of the label color). On the native LIGHT theme that produces washed-out,
// sub-WCAG-AA text (measured ~3.6:1 for secondary, worse for tertiary). These
// tokens are calibrated to clear WCAG-AA contrast on light backgrounds while
// keeping parity on dark backgrounds — and because every muted label routes
// through here, contrast is tunable in exactly one place.
extension Color {
    /// Adaptive replacement for `.secondary` foreground text.
    static let secondaryText = Color(nsColor: NSColor(name: nil) { appearance in
        // white 0.29 ≈ #4A4A4A on light (≈7:1 on white, ≈4.6:1 on the gray sidebar);
        // white 0.78 keeps a bright, legible gray on dark.
        appearance.isDark ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.29, alpha: 1)
    })

    /// Adaptive replacement for `.tertiary` foreground text (breadcrumbs,
    /// permissions strings, and other de-emphasized captions).
    static let tertiaryText = Color(nsColor: NSColor(name: nil) { appearance in
        // white 0.42 ≈ #6B6B6B on light (≈4.9:1 on white); white 0.62 on dark.
        appearance.isDark ? NSColor(white: 0.62, alpha: 1) : NSColor(white: 0.42, alpha: 1)
    })
}

// Leading-dot (`ShapeStyle`) access so these are a drop-in swap for the built-in
// hierarchical styles: `.foregroundStyle(.secondary)` -> `.foregroundStyle(.secondaryText)`.
extension ShapeStyle where Self == Color {
    static var secondaryText: Color { .secondaryText }
    static var tertiaryText: Color { .tertiaryText }
}
