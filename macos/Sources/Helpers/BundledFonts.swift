import Foundation
import CoreText

/// Registers the app-bundled monospaced fonts (JetBrains Mono, Fira Code,
/// Cascadia Code, IBM Plex Mono, Hack, Source Code Pro) into the current
/// process. Once registered they appear in the font picker and Ghostty resolves
/// them by name — CoreText/NSFontManager list each family once, so a bundled
/// font that's ALSO system-installed shows up only once (auto de-dup).
///
/// Registered with `.process` scope so it's app-local (no system-wide install),
/// and done as early as possible at launch so the configured font resolves.
enum BundledFonts {
    static func register() {
        // Synchronized-folder resources flatten to the Resources root, but also
        // check a Fonts/ subdir in case the layout preserves it.
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.path).inserted }
        guard !unique.isEmpty else { return }
        // Errors (e.g. a font already registered) are non-fatal — ignore them.
        _ = CTFontManagerRegisterFontsForURLs(unique as CFArray, .process, nil)
    }
}
